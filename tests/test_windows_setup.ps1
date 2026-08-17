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

function Unregister-ScheduledTask {
  param([string]$TaskName, [switch]$Confirm, $ErrorAction)
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
Invoke-SaUninstall | Out-Null

$unregistered = @(Get-Content $unregisterLog) | Sort-Object
$expectedTasks = @($script:SaAllTaskNames | ForEach-Object { "StayAwake\$_" }) | Sort-Object
Assert-Eq -Actual ($unregistered -join ',') -Expected ($expectedTasks -join ',') `
          -Name 'uninstall unregisters exactly the tasks setup registers (Disable, Restore, BootRestore)'
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
Invoke-SaUninstall -TimeoutSeconds 1 -PollMilliseconds 100 | Out-Null

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

Remove-Item $emptyHome -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
