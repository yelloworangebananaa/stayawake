$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'assert.ps1')

# See tests/test_state.ps1 for why this resolves to the long-name form.
$tempDir = (Get-Item $env:TEMP).FullName

$env:STAYAWAKE_HOME = Join-Path $tempDir "stayawake-locktest-$PID"
if (Test-Path $env:STAYAWAKE_HOME) { Remove-Item $env:STAYAWAKE_HOME -Recurse -Force }

. (Join-Path $here '..\lib\state.ps1')

# --- basic acquire/run/release ---
$result = Invoke-WithStateLock -MaxWaitSeconds 5 -Action { return 'ok' }
Assert-Eq -Actual $result -Expected 'ok' -Name 'lock action return value is propagated'
Assert-Eq -Actual (Test-Path (Get-LockDir)) -Expected $false -Name 'lock dir removed after clean release'

# --- sequential re-acquire (previous release must not wedge the next call) ---
$result2 = Invoke-WithStateLock -MaxWaitSeconds 5 -Action { return 'again' }
Assert-Eq -Actual $result2 -Expected 'again' -Name 'lock can be re-acquired after a clean release'

Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue

# --- stale lock (dead pid) is broken and the action still runs ---
New-Item -ItemType Directory -Force -Path (Get-LockDir) | Out-Null
Set-Content -Path (Join-Path (Get-LockDir) 'pid') -Value '999999' -Encoding utf8
$staleResult = Invoke-WithStateLock -MaxWaitSeconds 5 -Action { return 'broke-through' }
Assert-Eq -Actual $staleResult -Expected 'broke-through' -Name 'stale lock (dead holder pid) is broken, action runs'
Assert-Eq -Actual (Test-Path (Get-LockDir)) -Expected $false -Name 'lock dir removed after breaking a stale lock and releasing'

# --- Round 1 regression: a stale-break attempt that can never succeed (its
# target creation is blocked, e.g. because an earlier attempt's own cleanup
# silently failed and left a same-named leftover) must still RETURN within
# MaxWaitSeconds -- never spin forever with no timeout and no sleep. Forcing
# every possible break-target creation to fail via a deny ACL on the lock's
# parent directory, rather than pre-planting one specific guessed filename,
# makes this meaningful regardless of the exact naming scheme
# Invoke-WithStateLock happens to use internally (verified live on this
# machine: New-Item -ItemType Directory under a deny(WD,AD) ACL throws
# UnauthorizedAccessException, the same failure shape as the collision that
# caused the original hang).
Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Get-LockDir) | Out-Null
Set-Content -Path (Join-Path (Get-LockDir) 'pid') -Value '999999' -Encoding utf8
$stateDirLong = (Get-Item (Get-StateDir)).FullName
$aclUser = "$env:USERDOMAIN\$env:USERNAME"
icacls $stateDirLong /deny "${aclUser}:(OI)(CI)(WD,AD)" | Out-Null
try {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $spinResult = Invoke-WithStateLock -MaxWaitSeconds 2 -Action { return 'should-not-run' }
  $sw.Stop()
  Assert-Eq -Actual ($null -eq $spinResult) -Expected $true `
            -Name 'no-spin: a permanently-blocked stale-break still returns (action never runs)'
  # Generous upper bound -- this proves "bounded", not "instant". Under the
  # pre-fix code (unconditional `continue` around the wait/sleep gate) this
  # line is never reached at all; the process spins pinning a core forever.
  Assert-Eq -Actual ($sw.Elapsed.TotalSeconds -lt 15) -Expected $true `
            -Name 'no-spin: a permanently-blocked stale-break returns within a bounded time, not forever'
} finally {
  icacls $stateDirLong /remove:d "$aclUser" | Out-Null
}
Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue

# --- live lock: waiter must NOT proceed unlocked, must time out loudly ---
New-Item -ItemType Directory -Force -Path (Get-LockDir) | Out-Null
Set-Content -Path (Join-Path (Get-LockDir) 'pid') -Value "$PID" -Encoding utf8
$timedOut = Invoke-WithStateLock -MaxWaitSeconds 1 -Action { return 'should-not-run' }
Assert-Eq -Actual ($null -eq $timedOut) -Expected $true -Name 'live holder: waiter times out (returns $null), action never runs'
Remove-Item (Get-LockDir) -Recurse -Force -ErrorAction SilentlyContinue

# --- mutual exclusion under real concurrency: N processes racing, none may
# interleave -- AND with a dead-pid lock pre-planted, so the stale-break
# path itself is exercised under real multi-process contention, not just by
# a single caller in isolation. Whichever racer(s) see the lock first must
# race to break it before anyone can acquire; a double-break (two racers'
# Directory.Move both succeeding) would surface here as a lost or
# duplicated counter value, which the assertions below already catch
# directly -- no separate assertion needed for "was it broken exactly once".
Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue
$statePath = Join-Path $here '..\lib\state.ps1'
New-Item -ItemType Directory -Force -Path (Get-LockDir) | Out-Null
Set-Content -Path (Join-Path (Get-LockDir) 'pid') -Value '999999' -Encoding utf8
$n = 6
$jobs = 1..$n | ForEach-Object {
  Start-Job -ArgumentList $statePath, $env:STAYAWAKE_HOME -ScriptBlock {
    param($sp, $home_)
    $env:STAYAWAKE_HOME = $home_
    . $sp
    Invoke-WithStateLock -MaxWaitSeconds 20 -Action {
      $f = Join-Path (Get-StateDir) 'counter.txt'
      $v = 0
      if (Test-Path $f) { $v = [int](Get-Content $f -Raw) }
      Start-Sleep -Milliseconds 200
      Set-Content -Path $f -Value ($v + 1) -Encoding utf8
      return ($v + 1)
    }
  }
}
$results = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job
$counterFile = Join-Path $env:STAYAWAKE_HOME 'counter.txt'
$final = [int](Get-Content $counterFile -Raw)
Assert-Eq -Actual $final -Expected $n -Name "counter reaches $n with no lost updates under contention"
$sortedDistinct = @($results | Sort-Object -Unique)
Assert-Eq -Actual $sortedDistinct.Count -Expected $n -Name 'every racer observed a distinct serialized value (no interleaving)'
Assert-Eq -Actual (Test-Path (Get-LockDir)) -Expected $false -Name 'lock dir gone after all racers finish'

Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue

# --- Correction 2: a stray lock-break-target-shaped entry in the guards dir
# must not be counted as a guard, and Remove-DeadGuards must leave it alone
# -- same treatment as the '.tmp-*' case in test_state.ps1. Named after what
# Invoke-WithStateLock's stale-break actually generates ("lock.stale.<pid>.
# <guid>", no leading dot -- Windows has no dotfile convention), not a
# fictional ".stale.*" that production never produces.
$env:STAYAWAKE_HOME = Join-Path $tempDir "stayawake-locktest-stale-$PID"
if (Test-Path $env:STAYAWAKE_HOME) { Remove-Item $env:STAYAWAKE_HOME -Recurse -Force }
Register-Guard -SessionId 'sess-live' -Kind 'turn' -GuardPid $PID -ParentPid $PID
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'one real guard before stray stale entry'
$strayStale = Join-Path (Get-GuardsDir) "lock.stale.$PID.deadbeef00000000000000000000"
Set-Content -Path $strayStale -Value "guard_pid=$PID`nparent_pid=$PID" -Encoding utf8
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'stray lock.stale.* entry not counted in refcount'
Remove-DeadGuards
Assert-Eq -Actual (Test-Path $strayStale) -Expected $true -Name 'stray lock.stale.* entry left alone by reaper'
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'refcount unaffected by stray lock.stale.* entry after reap'
Remove-Item $strayStale -Force
Unregister-Guard -SessionId 'sess-live' -Kind 'turn'

Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue

Complete-Tests
