$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'assert.ps1')

# $env:TEMP is often set to an 8.3 short-name form when the profile directory
# name contains a space (e.g. "RYZEN9~1" for "ryzen 9"). Move-Item/Remove-Item
# fail to resolve that short form even though Test-Path/New-Item accept it --
# resolve to the long-name form once here so every path built from it works
# with every cmdlet. This is a test-setup wrinkle only; the module itself
# never touches $env:TEMP (its default state dir comes from $env:USERPROFILE).
$tempDir = (Get-Item $env:TEMP).FullName

$env:STAYAWAKE_HOME = Join-Path $tempDir "stayawake-test-$PID"
if (Test-Path $env:STAYAWAKE_HOME) { Remove-Item $env:STAYAWAKE_HOME -Recurse -Force }

. (Join-Path $here '..\lib\state.ps1')

# --- baseline is claimed exactly once ---
# Claim-Baseline is tri-state, not a bool: 0 = I created it, 1 = it already
# existed (another session owns it, safe to proceed), 2 = the write itself
# failed (caller must NOT proceed -- there is nothing to restore from).
Assert-Eq -Actual (Claim-Baseline -Text 'lidAc=1') -Expected 0 -Name 'first claim succeeds (0 = created)'
Assert-Eq -Actual (Claim-Baseline -Text 'lidAc=9') -Expected 1 -Name 'second claim is refused (1 = already exists)'
Assert-Eq -Actual (Read-Baseline) -Expected 'lidAc=1' -Name "baseline holds the first writer's value"

# --- a write failure is distinguishable from an existing claim ---
# Point STAYAWAKE_HOME at a path whose parent cannot be created: "blocker" is a
# regular file, so New-Item -Force on "blocker\sub\guards" fails because a file
# cannot have a subdirectory beneath it. Claim-Baseline must report 2 (do not
# proceed), never 1 (proceed, someone else has it) -- conflating the two would
# let a caller mutate the power setting with no baseline to restore from.
$savedHome = $env:STAYAWAKE_HOME
$blocker = Join-Path $tempDir "sa-blocker-$PID"
Set-Content -Path $blocker -Value 'x' -Encoding utf8
$env:STAYAWAKE_HOME = Join-Path $blocker 'sub'
Assert-Eq -Actual (Claim-Baseline -Text 'x') -Expected 2 -Name 'write failure (unwritable parent) returns 2, not 1'
Remove-Item $blocker -Force
$env:STAYAWAKE_HOME = $savedHome

# --- refcount ---
Assert-Eq -Actual (Get-GuardCount) -Expected 0 -Name 'no guards at start'
Register-Guard -SessionId 'sess-a' -Kind 'turn' -GuardPid $PID -ParentPid $PID
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'one guard after register'
Register-Guard -SessionId 'sess-a' -Kind 'pin' -GuardPid $PID -ParentPid $PID
Assert-Eq -Actual (Get-GuardCount) -Expected 2 -Name 'pin and turn coexist in one session'
Unregister-Guard -SessionId 'sess-a' -Kind 'turn'
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'unregister removes only its own file'

# --- dead guards are reaped, live ones are not ---
Register-Guard -SessionId 'sess-dead' -Kind 'turn' -GuardPid 999999 -ParentPid 999999
Assert-Eq -Actual (Get-GuardCount) -Expected 2 -Name 'dead guard counted before reaping'
Remove-DeadGuards
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'dead guard reaped, live guard kept'

# --- stray temp files are invisible to the refcount ---
# Windows has no dotfile convention: Get-ChildItem -File returns ".tmp-*" files
# normally, unlike POSIX glob which skips them for free. A stray temp file here
# simulates a force-kill mid-write inside Register-Guard. It must not be counted
# as a guard, and Remove-DeadGuards must leave it alone -- another session's
# in-flight write could legitimately look like this for a moment, and deleting
# it would risk a premature restore while that session is still working.
$strayTmp = Join-Path (Join-Path $env:STAYAWAKE_HOME 'guards') ".tmp-sess-b-turn-$PID"
Set-Content -Path $strayTmp -Value 'guard_pid=999999' -Encoding utf8
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'stray temp file not counted in refcount'
Remove-DeadGuards
Assert-Eq -Actual (Test-Path $strayTmp) -Expected $true -Name 'stray temp file left alone by reaper'
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'refcount unaffected by stray temp file after reap'
Remove-Item $strayTmp -Force

Unregister-Guard -SessionId 'sess-a' -Kind 'pin'
Assert-Eq -Actual (Get-GuardCount) -Expected 0 -Name 'all guards gone'
Clear-Baseline
Assert-Eq -Actual (Read-Baseline) -Expected '' -Name 'baseline cleared'

Remove-Item $env:STAYAWAKE_HOME -Recurse -Force

# --- ten concurrent claimers, exactly one wins ---
Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue
$statePath = Join-Path $here '..\lib\state.ps1'
$jobs = 1..10 | ForEach-Object {
  Start-Job -ArgumentList $statePath, $env:STAYAWAKE_HOME, $_ -ScriptBlock {
    param($sp, $home_, $i)
    $env:STAYAWAKE_HOME = $home_
    . $sp
    Claim-Baseline -Text "writer=$i"
  }
}
$results = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job
Assert-Eq -Actual (@($results | Where-Object { $_ -eq 0 }).Count) -Expected 1 `
          -Name 'exactly one concurrent claimer wins'
Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue

Complete-Tests
