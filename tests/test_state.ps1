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

# --- an unparseable (zero-byte) guard file is skipped, not fatal ---
# Get-Content -Raw on an empty file returns $null, and [regex]::Match($null, ...)
# throws MethodInvocationException instead of just failing to match. That
# would abort Remove-DeadGuards partway through and leave every remaining
# guard un-reaped. A live guard alongside the zero-byte file proves the loop
# keeps going rather than aborting on the first bad file.
Register-Guard -SessionId 'sess-live' -Kind 'turn' -GuardPid $PID -ParentPid $PID
$zeroByte = Get-GuardFile -SessionId 'sess-zero' -Kind 'turn'
New-Item -ItemType File -Force -Path $zeroByte | Out-Null
# 3 = sess-a/pin (still held from the refcount block above) + sess-live/turn + sess-zero/turn
Assert-Eq -Actual (Get-GuardCount) -Expected 3 -Name 'zero-byte guard file counted before reaping'
Remove-DeadGuards
Assert-Eq -Actual (Get-GuardCount) -Expected 3 -Name 'zero-byte guard file skipped, live guard untouched, reaper did not abort'
Remove-Item $zeroByte -Force
Unregister-Guard -SessionId 'sess-live' -Kind 'turn'

Unregister-Guard -SessionId 'sess-a' -Kind 'pin'
Assert-Eq -Actual (Get-GuardCount) -Expected 0 -Name 'all guards gone'
Clear-Baseline
Assert-Eq -Actual (Read-Baseline) -Expected '' -Name 'baseline cleared'

Remove-Item $env:STAYAWAKE_HOME -Recurse -Force

# --- STAYAWAKE_HOME under an 8.3 short-name path, exercised end to end ---
# Move-Item/Remove-Item fail to resolve a short-name path segment (e.g.
# "RYZEN9~1" for a profile directory named "ryzen 9") even though
# Test-Path/New-Item/Get-ChildItem/Get-Item accept it fine. STAYAWAKE_HOME is
# a caller-supplied override and can legitimately point under such a path.
# Without the fix in Register-Guard/Clear-Baseline/Unregister-Guard, this
# reproduces exactly: Claim-Baseline reports success (0) while Register-Guard
# silently fails to leave a real guard file behind, so the refcount never
# reflects reality.
$shortProfile = (cmd /c "for %A in (""$env:USERPROFILE"") do @echo %~sA").Trim()
if ($shortProfile -and ($shortProfile -ne $env:USERPROFILE) -and (Test-Path $shortProfile)) {
  $savedHome2 = $env:STAYAWAKE_HOME
  $env:STAYAWAKE_HOME = Join-Path $shortProfile "AppData\Local\Temp\stayawake-shorttest-$PID"
  if (Test-Path $env:STAYAWAKE_HOME) { Remove-Item $env:STAYAWAKE_HOME -Recurse -Force }

  Assert-Eq -Actual (Claim-Baseline -Text 'lidAc=short') -Expected 0 -Name 'short-name path: claim succeeds'
  Register-Guard -SessionId 'sess-short' -Kind 'turn' -GuardPid $PID -ParentPid $PID
  Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'short-name path: register actually produces a counted guard'
  Unregister-Guard -SessionId 'sess-short' -Kind 'turn'
  Assert-Eq -Actual (Get-GuardCount) -Expected 0 -Name 'short-name path: unregister actually removes the guard'
  Clear-Baseline
  Assert-Eq -Actual (Read-Baseline) -Expected '' -Name 'short-name path: clear actually clears the baseline'

  Remove-Item (Get-Item $env:STAYAWAKE_HOME).FullName -Recurse -Force -ErrorAction SilentlyContinue
  $env:STAYAWAKE_HOME = $savedHome2
} else {
  Write-Host "  skip short-name-path regression: no distinct 8.3 alias for `$env:USERPROFILE` on this machine"
}

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
# Distinguishing 1 (already exists) from 2 (write failed) under real
# contention is the entire point of Correction 1's tri-state return. If the
# nine losers came back 2 instead of 1, the count-of-0s assertion above would
# still pass while the actual guarantee (losers see "already exists", not an
# unexplained failure) would be broken.
Assert-Eq -Actual (@($results | Where-Object { $_ -eq 1 }).Count) -Expected 9 `
          -Name 'the nine losers all see "already exists" (1), not a write failure (2)'
Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue

Complete-Tests
