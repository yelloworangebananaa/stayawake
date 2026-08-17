$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'assert.ps1')

# See lib/state.ps1's Clear-Baseline header comment: %TEMP% can expand to an
# 8.3 short-name form when the profile directory name contains a space (this
# repo's own path does). Resolve through Get-Item once, same as
# test_windows_guard.ps1, so Move-Item/Remove-Item calls inside state.ps1
# never hit that trap.
$tempDir = (Get-Item $env:TEMP).FullName
$env:STAYAWAKE_HOME = Join-Path $tempDir "stayawake-setuptest-$PID"
if (Test-Path $env:STAYAWAKE_HOME) { Remove-Item $env:STAYAWAKE_HOME -Recurse -Force }
New-Item -ItemType Directory -Force -Path $env:STAYAWAKE_HOME | Out-Null

. (Join-Path $here '..\lib\state.ps1')

# Stub Invoke-RestoreState instead of sourcing lib/windows/platform.ps1 --
# these tests run on a machine with no admin rights, and the point of this
# file is the mode logic in Invoke-SaRestoreIfStale, not the live
# powercfg/scheduled-task calls.
$restoreLog = Join-Path $env:STAYAWAKE_HOME 'restore.log'
function Invoke-RestoreState {
  param([string]$Baseline)
  Add-Content -Path $restoreLog -Value "restore:$Baseline"
}

. (Join-Path $here '..\lib\windows\setup.ps1')

function Reset-RestoreLog { if (Test-Path $restoreLog) { Remove-Item $restoreLog -Force } }
function Get-RestoreLog {
  if (Test-Path $restoreLog) { return (Get-Content $restoreLog -Raw).Trim() }
  return ''
}

# --- normal mode: no baseline is a silent no-op ---
Reset-RestoreLog
Invoke-SaRestoreIfStale
Assert-Eq -Actual (Get-RestoreLog) -Expected '' -Name 'normal, no baseline: restore never called'

# --- normal mode: baseline present, no guards -> restores and clears ---
Claim-Baseline -Text 'lidAc=0;lidDc=0' | Out-Null
Reset-RestoreLog
Invoke-SaRestoreIfStale
Assert-Eq -Actual (Get-RestoreLog) -Expected 'restore:lidAc=0;lidDc=0' -Name 'normal, no guards: restores the baseline'
Assert-Eq -Actual (Read-Baseline) -Expected '' -Name 'normal, no guards: baseline cleared after restore'

# --- normal mode: a live guard blocks the restore ---
Claim-Baseline -Text 'lidAc=0;lidDc=0' | Out-Null
Register-Guard -SessionId 'sess-live' -Kind 'turn' -GuardPid $PID -ParentPid $PID
Reset-RestoreLog
Invoke-SaRestoreIfStale
Assert-Eq -Actual (Get-RestoreLog) -Expected '' -Name 'normal, live guard: restore not called'
Assert-Eq -Actual (Read-Baseline) -Expected 'lidAc=0;lidDc=0' -Name 'normal, live guard: baseline left intact'
Unregister-Guard -SessionId 'sess-live' -Kind 'turn'

# --- normal mode: a dead guard is reaped, then restore proceeds ---
Register-Guard -SessionId 'sess-dead' -Kind 'turn' -GuardPid 999999 -ParentPid 999999
Reset-RestoreLog
Invoke-SaRestoreIfStale
Assert-Eq -Actual (Get-RestoreLog) -Expected 'restore:lidAc=0;lidDc=0' -Name 'normal, dead guard: reaped and then restores'
Assert-Eq -Actual (Get-GuardCount) -Expected 0 -Name 'normal, dead guard: reaping removed it'
Clear-Baseline

# --- force mode: restores even with a live guard, and does not touch it ---
Claim-Baseline -Text 'lidAc=1;lidDc=1' | Out-Null
Register-Guard -SessionId 'sess-live2' -Kind 'turn' -GuardPid $PID -ParentPid $PID
Reset-RestoreLog
Invoke-SaRestoreIfStale -Mode 'force'
Assert-Eq -Actual (Get-RestoreLog) -Expected 'restore:lidAc=1;lidDc=1' -Name 'force: restores despite a live guard'
Assert-Eq -Actual (Read-Baseline) -Expected '' -Name 'force: baseline cleared'
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'force: does not reap or remove the live guard file itself'
Unregister-Guard -SessionId 'sess-live2' -Kind 'turn'

# $futureBootTime: I3 fix gates the boot-mode wipe on file age vs. boot time
# (see Invoke-SaRestoreIfStale's 'boot' branch and Get-SaBootTime injection).
# The two tests below plant guard files "now" and expect them wiped the same
# way the pre-fix unconditional wipe did -- pass a BootTime a few seconds in
# the future so those files read as pre-boot, so this suite doesn't depend on
# the real machine's uptime.
$futureBootTime = (Get-Date).AddSeconds(5)

# --- boot mode: a guard file whose PID happens to be alive (post-reboot PID
# reuse) must NOT block the restore -- this is the whole point of
# Correction 1. Normal mode with the same fixture would refuse to restore;
# boot must not.
Claim-Baseline -Text 'lidAc=1;lidDc=1' | Out-Null
Register-Guard -SessionId 'sess-reused-pid' -Kind 'turn' -GuardPid $PID -ParentPid $PID
Reset-RestoreLog
Invoke-SaRestoreIfStale -Mode 'boot' -BootTime $futureBootTime
Assert-Eq -Actual (Get-RestoreLog) -Expected 'restore:lidAc=1;lidDc=1' -Name 'boot: restores despite a live-looking guard PID'
Assert-Eq -Actual (Read-Baseline) -Expected '' -Name 'boot: baseline cleared'
Assert-Eq -Actual (Get-GuardCount) -Expected 0 -Name 'boot: pre-boot guard file wiped, no PID consulted'

# --- boot mode: no baseline -> guards still cleared, still silent, exit success ---
New-Item -ItemType Directory -Force -Path (Get-GuardsDir) | Out-Null
Set-Content -Path (Join-Path (Get-GuardsDir) 'leftover-guard') -Value 'junk' -Encoding utf8
Reset-RestoreLog
Invoke-SaRestoreIfStale -Mode 'boot' -BootTime $futureBootTime
Assert-Eq -Actual (Get-RestoreLog) -Expected '' -Name 'boot, no baseline: restore never called'
Assert-Eq -Actual (Get-GuardCount) -Expected 0 -Name 'boot, no baseline: pre-boot guard file still wiped'

# --- I3 fix: boot mode must NOT wipe a guard file written AFTER boot time.
# AtLogOn (which drives boot mode in production) also fires on RDP
# reconnect / fast user switching, not just an actual reboot -- a mid-turn
# logon must not delete the LIVE guard's file (that would make the guard's
# poll see its file gone, break, and restore mid-turn). Plant one guard file
# that predates a fake boot time and one that postdates it; only the
# pre-boot one may be removed.
New-Item -ItemType Directory -Force -Path (Get-GuardsDir) | Out-Null
$fakeBoot = Get-Date
$preBootFile  = Join-Path (Get-GuardsDir) 'sess-preboot-turn'
$postBootFile = Join-Path (Get-GuardsDir) 'sess-postboot-turn'
Set-Content -Path $preBootFile -Value "guard_pid=1`nparent_pid=1" -Encoding utf8
(Get-Item $preBootFile).LastWriteTime = $fakeBoot.AddSeconds(-30)
Set-Content -Path $postBootFile -Value "guard_pid=$PID`nparent_pid=$PID" -Encoding utf8
(Get-Item $postBootFile).LastWriteTime = $fakeBoot.AddSeconds(30)

Invoke-SaRestoreIfStale -Mode 'boot' -BootTime $fakeBoot
Assert-Eq -Actual (Test-Path $preBootFile) -Expected $false -Name 'I3: pre-boot guard file removed'
Assert-Eq -Actual (Test-Path $postBootFile) -Expected $true -Name 'I3: post-boot (mid-session logon) guard file left alone'
Remove-Item $postBootFile -Force -ErrorAction SilentlyContinue

# --- single source of truth: the task list Invoke-SaUninstall iterates is
# built from the same names Invoke-SaSetup registers (see the
# $script:SaElevatedTaskNames / $script:SaBootTaskName / $script:SaAllTaskNames
# definitions in lib/windows/setup.ps1). Pin the exact set and order so a
# future edit that adds a task to one but not the other fails loudly here.
Assert-Eq -Actual ($script:SaAllTaskNames -join ',') -Expected 'Disable,Restore,BootRestore' `
          -Name 'task list: Disable, Restore, BootRestore, derived from one source'

# --- BootRestore's action must resolve to BOOT mode, not normal mode ---
# Normal mode consults guard liveness (Test-PidAlive); a recycled PID making
# a dead guard look alive is exactly what would block the restore, and
# Windows recycles PIDs faster than POSIX. Get-SaBootRestoreArgument is a
# pure string builder pulled out of Invoke-SaSetup for exactly this reason:
# it's checkable without touching Register-ScheduledTask or powercfg.
$bootArg = Get-SaBootRestoreArgument -StayawakeScript 'C:\fake\bin\stayawake.ps1'
Assert-Eq -Actual ($bootArg -match '-Verb restore-if-stale') -Expected $true `
          -Name 'BootRestore action invokes the restore-if-stale verb'
Assert-Eq -Actual ($bootArg -match '-SessionId boot\b') -Expected $true `
          -Name 'BootRestore action selects boot mode via -SessionId boot, not normal mode'

# --- Invoke-SaUninstall removes every task Invoke-SaSetup registers ---
# Stub Unregister-ScheduledTask (a real cmdlet) with a same-named function --
# PowerShell resolves an unqualified command to a function ahead of a cmdlet
# of the same name, so this shadows the real one for the duration of
# Invoke-SaUninstall without touching Task Scheduler at all. The log lives
# outside STAYAWAKE_HOME because Invoke-SaUninstall recursively deletes the
# state dir as its last step -- a log inside it would vanish with it.
$uninstallOutDir = Join-Path $tempDir "stayawake-uninstalltest-$PID"
if (Test-Path $uninstallOutDir) { Remove-Item $uninstallOutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $uninstallOutDir | Out-Null
$unregisterLog = Join-Path $uninstallOutDir 'unregister.log'
$uninstallRestoreLog = Join-Path $uninstallOutDir 'restore.log'
$raceLog = Join-Path $uninstallOutDir 'race.log'

# I-critical fix: Get-ScheduledTask is the existence-check the fixed
# Invoke-SaUninstall calls before unregistering each task; stub it truthy so
# the loop actually reaches Unregister-ScheduledTask below.
$taskPathLog = Join-Path $uninstallOutDir 'taskpath.log'
function Get-ScheduledTask {
  param([string]$TaskName, [string]$TaskPath, $ErrorAction)
  return [pscustomobject]@{ TaskName = $TaskName; TaskPath = $TaskPath }
}
function Unregister-ScheduledTask {
  # TaskPath capture is the point of this stub. Unregister-ScheduledTask is a
  # CDXML instance cmdlet whose TaskName lookup matches only the leaf CIM
  # property ("Restore"), never the combined "StayAwake\Restore" form -- the
  # old stub here asserted only that the loop iterated $script:SaAllTaskNames,
  # never that the argument form would actually resolve against the real
  # cmdlet. That is exactly what hid the bug. Recording -TaskPath and
  # asserting on it below pins the split form.
  param([string]$TaskName, [string]$TaskPath, [switch]$Confirm, $ErrorAction)
  # C2 regression guard: production's Invoke-RestoreState only QUEUES the
  # "Restore" task (schtasks /run returns on queue, not completion -- see
  # lib/windows/platform.ps1). Get-ScheduledTaskInfo below models that by
  # reporting the task as still 'Running' for its first few polls before
  # flipping to completed. If Unregister-ScheduledTask is reached before
  # that flip, the code under test unregistered/deleted the restore
  # mechanism while the real-world restore could still be in flight -- the
  # exact race C2 describes. Record it rather than failing loudly here so
  # every subsequent assertion in this block still runs.
  if (-not $script:restoreTaskCompleted) {
    Add-Content -Path $raceLog -Value "RACE:$TaskName unregistered before Restore task finished"
  }
  Add-Content -Path $unregisterLog -Value $TaskName
  Add-Content -Path $taskPathLog -Value $TaskPath
}
# Redefines the Invoke-RestoreState stub to log outside STAYAWAKE_HOME for
# the same reason as $unregisterLog above; nothing later in this file needs
# the original definition.
function Invoke-RestoreState {
  param([string]$Baseline)
  Add-Content -Path $uninstallRestoreLog -Value "restore:$Baseline"
}

# Async Get-ScheduledTaskInfo stub: call 1 is Invoke-SaUninstall's baseline
# LastRunTime capture (before the restore is even queued); calls 2 and 3
# simulate the task still being 'Running' (queued but not finished); call 4+
# reports it finished with an advanced LastRunTime. Only the fixed code
# (which polls via Wait-SaRestoreTaskComplete) can ever observe the
# completed state before touching Unregister-ScheduledTask.
$script:sgtiCalls = 0
$script:restoreTaskCompleted = $false
function Get-ScheduledTaskInfo {
  param([string]$TaskName, $ErrorAction)
  $script:sgtiCalls++
  if ($script:sgtiCalls -le 3) {
    return [pscustomobject]@{ LastRunTime = [datetime]'2020-01-01'; State = 'Running' }
  }
  $script:restoreTaskCompleted = $true
  return [pscustomobject]@{ LastRunTime = (Get-Date); State = 'Ready' }
}

Claim-Baseline -Text 'lidAc=1;lidDc=1' | Out-Null
$rc = Invoke-SaUninstall

$unregistered = @(Get-Content $unregisterLog) | Sort-Object
$expectedTasks = @($script:SaAllTaskNames) | Sort-Object
Assert-Eq -Actual ($unregistered -join ',') -Expected ($expectedTasks -join ',') `
          -Name 'uninstall unregisters exactly the tasks setup registers (Disable, Restore, BootRestore)'
$taskPaths = @(Get-Content $taskPathLog) | Sort-Object -Unique
Assert-Eq -Actual ($taskPaths -join ',') -Expected '\StayAwake\' `
          -Name 'uninstall unregisters using the split TaskName/TaskPath form the real cmdlet requires'
Assert-Eq -Actual $rc -Expected 0 -Name 'uninstall returns 0 on success'
Assert-Eq -Actual ((Get-Content $uninstallRestoreLog -Raw).Trim()) -Expected 'restore:lidAc=1;lidDc=1' `
          -Name 'uninstall restores (force mode) before removing tasks'
Assert-Eq -Actual (Test-Path $env:STAYAWAKE_HOME) -Expected $false -Name 'uninstall removes the state directory'
Assert-Eq -Actual (Test-Path $raceLog) -Expected $false `
          -Name 'C2: uninstall waits for the async Restore task to finish before unregistering (no race)'

Remove-Item $uninstallOutDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue

# --- C2: on timeout, leave tasks registered and state intact rather than
# stranding the user with no tooling. Get-ScheduledTaskInfo below never
# reports completion, forcing Wait-SaRestoreTaskComplete to time out; a
# short TimeoutSeconds/PollMilliseconds keeps this test fast.
$timeoutOutDir = Join-Path $tempDir "stayawake-uninstalltimeouttest-$PID"
if (Test-Path $timeoutOutDir) { Remove-Item $timeoutOutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $timeoutOutDir | Out-Null
$env:STAYAWAKE_HOME = $timeoutOutDir
$timeoutUnregisterLog = Join-Path $tempDir "stayawake-timeout-unregister-$PID.log"
if (Test-Path $timeoutUnregisterLog) { Remove-Item $timeoutUnregisterLog -Force }

function Get-ScheduledTaskInfo {
  param([string]$TaskName, $ErrorAction)
  return [pscustomobject]@{ LastRunTime = [datetime]'2020-01-01'; State = 'Running' }
}
function Unregister-ScheduledTask {
  param([string]$TaskName, [switch]$Confirm, $ErrorAction)
  Add-Content -Path $timeoutUnregisterLog -Value $TaskName
}
function Invoke-RestoreState {
  param([string]$Baseline)
}

Claim-Baseline -Text 'lidAc=1;lidDc=1' | Out-Null
$rc = Invoke-SaUninstall -TimeoutSeconds 1 -PollMilliseconds 100

Assert-Eq -Actual (Test-Path $timeoutUnregisterLog) -Expected $false `
          -Name 'C2 timeout: scheduled tasks left registered when the restore never completes'
# Baseline bookkeeping (original.state) is cleared by Invoke-SaRestoreIfStale
# itself as soon as the restore is queued -- unrelated to whether the
# scheduled task has finished. What matters for the retry story is that the
# task stays registered (asserted above) and restore.state -- the file the
# still-running task actually needs -- survives because the state dir below
# is not torn down.
Assert-Eq -Actual (Test-Path $env:STAYAWAKE_HOME) -Expected $true `
          -Name 'C2 timeout: state directory left intact so the still-registered task can still finish'
Assert-Eq -Actual $rc -Expected 1 -Name 'C2 timeout: uninstall returns non-zero so a wrapper can tell it failed'
# Timeout-retry fix: without rewriting original.state on timeout, a SECOND
# uninstall attempt would find Read-Baseline empty ($hadBaseline = $false),
# skip Wait-SaRestoreTaskComplete entirely, and go straight to unregistering
# tasks + deleting state -- exactly the catastrophe the wait exists to
# prevent. This is the direct, minimal check that the rewrite happened.
Assert-Eq -Actual ([bool](Read-Baseline)) -Expected $true `
          -Name 'timeout retry fix: baseline rewritten on timeout so a retry still has something to wait on'

# --- the regression that actually matters: a SECOND uninstall attempt after
# a timeout must still WAIT on the restore task, not skip straight to
# deletion. This time the task genuinely finishes -- track whether the wait
# actually polled at all, proving the retry did not take the no-baseline
# shortcut.
$script:retryPolled = $false
$script:retryCalls = 0
function Get-ScheduledTaskInfo {
  param([string]$TaskName, $ErrorAction)
  $script:retryPolled = $true
  $script:retryCalls++
  if ($script:retryCalls -le 3) {
    return [pscustomobject]@{ LastRunTime = [datetime]'2020-01-01'; State = 'Running' }
  }
  return [pscustomobject]@{ LastRunTime = (Get-Date); State = 'Ready' }
}
$rc2 = Invoke-SaUninstall -TimeoutSeconds 5 -PollMilliseconds 100

Assert-Eq -Actual $script:retryPolled -Expected $true `
          -Name 'retry after timeout: second attempt still waits on the restore task instead of skipping straight to deletion'
Assert-Eq -Actual $rc2 -Expected 0 -Name 'retry after timeout: succeeds once the restore genuinely completes'
Assert-Eq -Actual (Test-Path $timeoutUnregisterLog) -Expected $true `
          -Name 'retry after timeout: tasks unregistered once the wait actually completes'
Assert-Eq -Actual (Test-Path $env:STAYAWAKE_HOME) -Expected $false `
          -Name 'retry after timeout: state directory removed after a successful retry'

Remove-Item $timeoutOutDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $timeoutUnregisterLog -Force -ErrorAction SilentlyContinue

# --- C2: no baseline -> uninstall does not block ~30s waiting on a no-op ---
$noBaselineOutDir = Join-Path $tempDir "stayawake-uninstallnobaseline-$PID"
if (Test-Path $noBaselineOutDir) { Remove-Item $noBaselineOutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $noBaselineOutDir | Out-Null
$env:STAYAWAKE_HOME = $noBaselineOutDir
$script:sgtiCalledForNoBaseline = $false
function Get-ScheduledTaskInfo {
  param([string]$TaskName, $ErrorAction)
  $script:sgtiCalledForNoBaseline = $true
  return [pscustomobject]@{ LastRunTime = [datetime]'2020-01-01'; State = 'Ready' }
}
function Unregister-ScheduledTask {
  param([string]$TaskName, [switch]$Confirm, $ErrorAction)
}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Invoke-SaUninstall | Out-Null
$sw.Stop()
Assert-Eq -Actual ($sw.Elapsed.TotalSeconds -lt 5) -Expected $true `
          -Name 'C2: no-baseline uninstall returns quickly, does not wait out the timeout'
Assert-Eq -Actual $script:sgtiCalledForNoBaseline -Expected $false `
          -Name 'C2: no-baseline uninstall never polls Get-ScheduledTaskInfo (nothing was queued to wait for)'

Remove-Item $noBaselineOutDir -Recurse -Force -ErrorAction SilentlyContinue

# --- verb dispatch through bin/stayawake.ps1, run as real subprocesses so the
# real ValidateSet / switch / dot-sourcing chain is exercised end to end.
# These are safe: an unknown verb never reaches Invoke-Sa*, and
# restore-if-stale against an empty STAYAWAKE_HOME returns before any
# powercfg/scheduled-task call is made (Read-Baseline is empty).
$stayawake = Join-Path $here '..\bin\stayawake.ps1'

& powershell -NoProfile -ExecutionPolicy Bypass -File $stayawake -Verb bogus 2>$null 1>$null
Assert-Eq -Actual ($LASTEXITCODE -ne 0) -Expected $true -Name 'unknown verb: non-zero exit'

$emptyHome = Join-Path $tempDir "stayawake-emptytest-$PID"
if (Test-Path $emptyHome) { Remove-Item $emptyHome -Recurse -Force }
New-Item -ItemType Directory -Force -Path $emptyHome | Out-Null
$env:STAYAWAKE_HOME = $emptyHome

$out = & powershell -NoProfile -ExecutionPolicy Bypass -File $stayawake -Verb restore-if-stale
$rc = $LASTEXITCODE
Assert-Eq -Actual $rc -Expected 0 -Name 'restore-if-stale, empty STAYAWAKE_HOME: exit 0'
Assert-Eq -Actual ($out -join '') -Expected '' -Name 'restore-if-stale, empty STAYAWAKE_HOME: no output'

# --- status runs cleanly without setup and without elevation (brief Step 3) ---
# This is a real subprocess through the real platform.ps1: Get-LidActionLive
# and the Modern Standby check are read-only `powercfg /query` / `powercfg /a`
# calls, never a write. Safe to run unprivileged.
$statusOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File $stayawake -Verb status) -join "`n"
$rcStatus = $LASTEXITCODE
Assert-Eq -Actual $rcStatus -Expected 0 -Name 'status: exits 0 without setup or elevation'
Assert-Eq -Actual ($statusOut -match 'grant:\s+NOT installed') -Expected $true -Name 'status: reports grant not installed'
Assert-Eq -Actual ($statusOut -match 'guards:\s+0 active') -Expected $true -Name 'status: reports zero guards'
Assert-Eq -Actual ($statusOut -match 'baseline:\s+none') -Expected $true -Name 'status: baseline reads none'
# Fix 5: there is no `stayawake` binary on PATH -- the real interface is the
# `/stayawake` slash command. The old message told users to run a command
# that does not exist.
Assert-Eq -Actual ($statusOut -match '/stayawake setup') -Expected $true `
          -Name 'Fix 5: NOT installed message points at the /stayawake slash command, not a bare binary'
Assert-Eq -Actual ($statusOut -match '(?<!/)stayawake setup') -Expected $false `
          -Name 'Fix 5: NOT installed message never says the bare (non-slash) form'

Remove-Item $emptyHome -Recurse -Force -ErrorAction SilentlyContinue

# --- Fix 1: Invoke-SaStatus must probe the whole task set, not just Disable,
# so a partial install (or one predating BootRestore) is visible instead of
# silently reporting "installed". Stub Get-ScheduledTask in-process; these
# are pure decision-logic tests, not live Task Scheduler calls.
function New-FakeTaskAction { param([string]$Arguments) [pscustomobject]@{ Execute = 'powershell.exe'; Arguments = $Arguments } }
function New-FakeTask {
  param([string]$TaskName, [string]$ScriptPath = 'C:\fake\ok.ps1')
  [pscustomobject]@{
    TaskName = $TaskName
    Actions  = @(New-FakeTaskAction -Arguments "-NoProfile -File `"$ScriptPath`" -Action $TaskName")
  }
}

# All three present -> "installed", no PARTIAL/BROKEN line.
function Get-ScheduledTask {
  param([string]$TaskName, [string]$TaskPath, $ErrorAction)
  return New-FakeTask -TaskName $TaskName -ScriptPath $PSCommandPath
}
$out = (Invoke-SaStatus *>&1 | Out-String)
Assert-Eq -Actual ($out -match 'grant:\s+installed') -Expected $true -Name 'Fix 1: all three tasks present reports installed'
Assert-Eq -Actual ($out -match 'PARTIAL') -Expected $false -Name 'Fix 1: complete install never reports PARTIAL'

# Only "Disable" present (the exact partial-install scenario the fix
# targets: an old install predating BootRestore, or one interrupted
# mid-setup) -> must NOT report "installed", and must name what's missing.
function Get-ScheduledTask {
  param([string]$TaskName, [string]$TaskPath, $ErrorAction)
  if ($TaskName -eq 'Disable') { return New-FakeTask -TaskName $TaskName -ScriptPath $PSCommandPath }
  return $null
}
$out = (Invoke-SaStatus *>&1 | Out-String)
Assert-Eq -Actual ($out -match 'grant:\s+installed \(') -Expected $false `
          -Name 'Fix 1: partial install (Disable only) never reports bare installed'
Assert-Eq -Actual ($out -match 'PARTIAL') -Expected $true -Name 'Fix 1: partial install reports PARTIAL'
Assert-Eq -Actual ($out -match 'Restore') -Expected $true -Name 'Fix 1: partial install names the missing Restore task'
Assert-Eq -Actual ($out -match 'BootRestore') -Expected $true -Name 'Fix 1: partial install names the missing BootRestore task (the logon backstop)'

# --- Fix 2: Get-SaTaskScriptPath is the pure string extractor behind the
# path-resolves check -- verify it directly, same pattern as
# Get-SaBootRestoreArgument above.
$extracted = Get-SaTaskScriptPath -Arguments '-NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\stayawake\lib\windows\lid.ps1" -Action Disable'
Assert-Eq -Actual $extracted -Expected 'C:\Program Files\stayawake\lib\windows\lid.ps1' `
          -Name 'Fix 2: Get-SaTaskScriptPath extracts the quoted -File path'
Assert-Eq -Actual (Get-SaTaskScriptPath -Arguments '-NoProfile -Verb restore-if-stale') -Expected '' `
          -Name 'Fix 2: Get-SaTaskScriptPath returns empty when there is no -File argument'

# All three tasks registered, but the embedded script path does not exist on
# disk -- the relocated-install-root scenario the fix targets. Every task
# must be checked, including BootRestore (one of the four restore triggers).
function Get-ScheduledTask {
  param([string]$TaskName, [string]$TaskPath, $ErrorAction)
  return New-FakeTask -TaskName $TaskName -ScriptPath 'C:\this\path\does\not\exist\stayawake\lid.ps1'
}
$out = (Invoke-SaStatus *>&1 | Out-String)
Assert-Eq -Actual ($out -match 'BROKEN') -Expected $true -Name 'Fix 2: relocated install root is reported as BROKEN'
Assert-Eq -Actual ($out -match 'Disable') -Expected $true -Name 'Fix 2: BROKEN line names the Disable task'
Assert-Eq -Actual ($out -match 'Restore') -Expected $true -Name 'Fix 2: BROKEN line names the Restore task'
Assert-Eq -Actual ($out -match 'BootRestore') -Expected $true -Name 'Fix 2: BROKEN line names the BootRestore task (the logon backstop)'

# Control: all three present and pointing at a real, existing file -> no
# BROKEN line. Proves the check discriminates on resolvability, not merely
# on the task existing.
function Get-ScheduledTask {
  param([string]$TaskName, [string]$TaskPath, $ErrorAction)
  return New-FakeTask -TaskName $TaskName -ScriptPath $PSCommandPath
}
$out = (Invoke-SaStatus *>&1 | Out-String)
Assert-Eq -Actual ($out -match 'BROKEN') -Expected $false -Name 'Fix 2: a resolvable install root never reports BROKEN'

# --- Fix 3: boot mode must not silently no-op when boot time can't be
# determined -- warn to stderr, skip the wipe on purpose, and still restore.
# Run as a real subprocess: [Console]::Error.WriteLine bypasses PowerShell's
# error stream and writes to the OS stderr handle directly, which only a
# child process's stream redirection (2>&1 on a native invocation) reliably
# captures.
$bootFailDir = Join-Path $tempDir "stayawake-bootfail-$PID"
if (Test-Path $bootFailDir) { Remove-Item $bootFailDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $bootFailDir | Out-Null
$bootFailHome = Join-Path $bootFailDir 'home'
$bootFailRestoreLog = Join-Path $bootFailDir 'restore.log'
$bootFailScript = Join-Path $bootFailDir 'run.ps1'
$libStatePath = (Join-Path $here '..\lib\state.ps1')
$libSetupPath = (Join-Path $here '..\lib\windows\setup.ps1')
@"
`$env:STAYAWAKE_HOME = '$bootFailHome'
. '$libStatePath'
# Shadowing Get-CimInstance with a function: PowerShell resolves an
# unqualified command to a function ahead of a cmdlet of the same name, so
# this fails the boot-time lookup without touching WMI/CIM at all.
function Get-CimInstance { throw 'simulated WMI failure' }
. '$libSetupPath'
function Invoke-RestoreState { param([string]`$Baseline) Add-Content -Path '$bootFailRestoreLog' -Value "restore:`$Baseline" }
Claim-Baseline -Text 'lidAc=9;lidDc=9' | Out-Null
New-Item -ItemType Directory -Force -Path (Get-GuardsDir) | Out-Null
Set-Content -Path (Join-Path (Get-GuardsDir) 'leftover-guard') -Value 'junk' -Encoding utf8
Invoke-SaRestoreIfStale -Mode 'boot'
if (Test-Path (Join-Path (Get-GuardsDir) 'leftover-guard')) { Write-Host 'GUARD-STILL-PRESENT' }
"@ | Set-Content -Path $bootFailScript -Encoding utf8
$bootFailOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File $bootFailScript 2>&1 | Out-String)
Assert-Eq -Actual ($bootFailOut -match 'could not determine boot time') -Expected $true `
          -Name 'Fix 3: unparseable boot time warns to stderr'
Assert-Eq -Actual ($bootFailOut -match 'GUARD-STILL-PRESENT') -Expected $true `
          -Name 'Fix 3: unparseable boot time skips the wipe (safe direction preserved)'
Assert-Eq -Actual ((Get-Content $bootFailRestoreLog -Raw).Trim()) -Expected 'restore:lidAc=9;lidDc=9' `
          -Name 'Fix 3: restore still proceeds when boot time is unknown'
Remove-Item $bootFailDir -Recurse -Force -ErrorAction SilentlyContinue

# --- Fix 4: schtasks exit codes in lib/windows/platform.ps1's
# Invoke-ApplyState / Invoke-RestoreState were discarded. A non-zero exit
# means the run was never even queued (e.g. the task was uninstalled while a
# guard is still live) and must be surfaced on stderr -- but never thrown,
# since a guard mid-cleanup must still finish its remaining teardown. Real
# subprocess for the same [Console]::Error.WriteLine reason as Fix 3.
$schtasksFailDir = Join-Path $tempDir "stayawake-schtasksfail-$PID"
if (Test-Path $schtasksFailDir) { Remove-Item $schtasksFailDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $schtasksFailDir | Out-Null
$schtasksFailHome = Join-Path $schtasksFailDir 'home'
New-Item -ItemType Directory -Force -Path $schtasksFailHome | Out-Null
$schtasksFailScript = Join-Path $schtasksFailDir 'run.ps1'
$libPlatformPath = (Join-Path $here '..\lib\windows\platform.ps1')
@"
`$env:STAYAWAKE_HOME = '$schtasksFailHome'
. '$libStatePath'
# Shadowing schtasks with a function the same way the repo's own tests
# shadow Unregister-ScheduledTask elsewhere: PowerShell resolves an
# unqualified command to a function ahead of a native executable of the same
# name, so this simulates a failed queue attempt without touching Task
# Scheduler.
function schtasks { `$global:LASTEXITCODE = 1; return 'ERROR: The system cannot find the file specified.' }
. '$libPlatformPath'
Invoke-ApplyState
Invoke-RestoreState -Baseline 'lidAc=2;lidDc=2'
Write-Host 'REACHED-END'
"@ | Set-Content -Path $schtasksFailScript -Encoding utf8
$schtasksFailOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schtasksFailScript 2>&1 | Out-String)
Assert-Eq -Actual ($schtasksFailOut -match 'StayAwake\\Disable') -Expected $true `
          -Name 'Fix 4: Invoke-ApplyState warns on stderr when schtasks fails to queue Disable'
Assert-Eq -Actual ($schtasksFailOut -match 'StayAwake\\Restore') -Expected $true `
          -Name 'Fix 4: Invoke-RestoreState warns on stderr when schtasks fails to queue Restore'
Assert-Eq -Actual ($schtasksFailOut -match 'REACHED-END') -Expected $true `
          -Name 'Fix 4: a failed schtasks queue does not throw -- caller teardown still completes'
Assert-Eq -Actual (Test-Path (Join-Path $schtasksFailHome 'restore.state')) -Expected $true `
          -Name 'Fix 4: restore.state is still written even when schtasks fails to queue the run'
Remove-Item $schtasksFailDir -Recurse -Force -ErrorAction SilentlyContinue

Complete-Tests
