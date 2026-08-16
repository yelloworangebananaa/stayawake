$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'assert.ps1')

# See tests/test_state.ps1 for why this resolves to the long-name form.
$tempDir = (Get-Item $env:TEMP).FullName

$env:STAYAWAKE_HOME = Join-Path $tempDir "stayawake-locktest-$PID"
if (Test-Path $env:STAYAWAKE_HOME) { Remove-Item $env:STAYAWAKE_HOME -Recurse -Force }

. (Join-Path $here '..\lib\state.ps1')

# --- basic acquire/run/release ---
$ran = $false
$result = Invoke-WithStateLock -MaxWaitSeconds 5 -Action { $script:ran2 = $true; return 'ok' }
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

# --- live lock: waiter must NOT proceed unlocked, must time out loudly ---
New-Item -ItemType Directory -Force -Path (Get-LockDir) | Out-Null
Set-Content -Path (Join-Path (Get-LockDir) 'pid') -Value "$PID" -Encoding utf8
$timedOut = Invoke-WithStateLock -MaxWaitSeconds 1 -Action { return 'should-not-run' }
Assert-Eq -Actual ($null -eq $timedOut) -Expected $true -Name 'live holder: waiter times out (returns $null), action never runs'
Remove-Item (Get-LockDir) -Recurse -Force -ErrorAction SilentlyContinue

# --- mutual exclusion under real concurrency: N processes racing, none may interleave ---
Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue
$statePath = Join-Path $here '..\lib\state.ps1'
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

# --- Correction 2: a stray '.stale.*' entry in the guards dir must not be
# counted as a guard, and Remove-DeadGuards must leave it alone -- same
# treatment as the '.tmp-*' case in test_state.ps1.
$env:STAYAWAKE_HOME = Join-Path $tempDir "stayawake-locktest-stale-$PID"
if (Test-Path $env:STAYAWAKE_HOME) { Remove-Item $env:STAYAWAKE_HOME -Recurse -Force }
Register-Guard -SessionId 'sess-live' -Kind 'turn' -GuardPid $PID -ParentPid $PID
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'one real guard before stray stale entry'
$strayStale = Join-Path (Get-GuardsDir) ".stale.$PID"
Set-Content -Path $strayStale -Value "guard_pid=$PID`nparent_pid=$PID" -Encoding utf8
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'stray .stale.* entry not counted in refcount'
Remove-DeadGuards
Assert-Eq -Actual (Test-Path $strayStale) -Expected $true -Name 'stray .stale.* entry left alone by reaper'
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'refcount unaffected by stray .stale.* entry after reap'
Remove-Item $strayStale -Force
Unregister-Guard -SessionId 'sess-live' -Kind 'turn'

Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue

Complete-Tests
