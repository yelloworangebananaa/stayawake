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

# --- boot mode: a guard file whose PID happens to be alive (post-reboot PID
# reuse) must NOT block the restore -- this is the whole point of
# Correction 1. Normal mode with the same fixture would refuse to restore;
# boot must not.
Claim-Baseline -Text 'lidAc=1;lidDc=1' | Out-Null
Register-Guard -SessionId 'sess-reused-pid' -Kind 'turn' -GuardPid $PID -ParentPid $PID
Reset-RestoreLog
Invoke-SaRestoreIfStale -Mode 'boot'
Assert-Eq -Actual (Get-RestoreLog) -Expected 'restore:lidAc=1;lidDc=1' -Name 'boot: restores despite a live-looking guard PID'
Assert-Eq -Actual (Read-Baseline) -Expected '' -Name 'boot: baseline cleared'
Assert-Eq -Actual (Get-GuardCount) -Expected 0 -Name 'boot: guards directory wiped unconditionally, no PID consulted'

# --- boot mode: no baseline -> guards still cleared, still silent, exit success ---
New-Item -ItemType Directory -Force -Path (Get-GuardsDir) | Out-Null
Set-Content -Path (Join-Path (Get-GuardsDir) 'leftover-guard') -Value 'junk' -Encoding utf8
Reset-RestoreLog
Invoke-SaRestoreIfStale -Mode 'boot'
Assert-Eq -Actual (Get-RestoreLog) -Expected '' -Name 'boot, no baseline: restore never called'
Assert-Eq -Actual (Get-GuardCount) -Expected 0 -Name 'boot, no baseline: guards directory still wiped'

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

function Unregister-ScheduledTask {
  param([string]$TaskName, [switch]$Confirm, $ErrorAction)
  Add-Content -Path $unregisterLog -Value $TaskName
}
# Redefines the Invoke-RestoreState stub to log outside STAYAWAKE_HOME for
# the same reason as $unregisterLog above; nothing later in this file needs
# the original definition.
function Invoke-RestoreState {
  param([string]$Baseline)
  Add-Content -Path $uninstallRestoreLog -Value "restore:$Baseline"
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

Remove-Item $uninstallOutDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue

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
