# usage: guard.ps1 -SessionId <id> -Kind <kind> -ParentPid <pid>
# Holds the machine awake until the parent dies, its guard file is removed,
# or the battery drops below the floor. Restores on every exit path this
# process can reach via try/finally (normal exit, Ctrl-C). A force-kill
# (Stop-Process -Force) skips try/finally entirely -- exactly like a shell
# trap does not survive kill -9 -- and is covered instead by three other
# layers: the parent-pid poll of sibling guards, sibling guards' own
# Remove-DeadGuards reap of this guard's file, and the logon Restore
# scheduled task. Do not try to defeat that with more PowerShell machinery.
#
# Windows twin of bin/guard.sh. See that file's comments for the full
# rationale behind each ordering; only Windows-specific deltas are repeated
# here.
param(
  [Parameter(Mandatory=$true)][string]$SessionId,
  [Parameter(Mandatory=$true)][string]$Kind,
  [Parameter(Mandatory=$true)][int]$ParentPid
)

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\state.ps1')
if ($env:STAYAWAKE_PLATFORM_STUB) {
  . $env:STAYAWAKE_PLATFORM_STUB
} else {
  . (Join-Path $root 'lib\windows\platform.ps1')

  Add-Type -Namespace SA -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@

  # ES_DISPLAY_REQUIRED is deliberately omitted so the screen still sleeps --
  # this only blocks idle *system* sleep, not display sleep. That is a
  # feature, not an oversight.
  function Set-IdleAssertion {
    param([bool]$On)
    # PowerShell parses a hex literal as [int] first, and 0x80000000 as an
    # [int] is -2147483648 -- casting that negative value to [uint32] throws
    # ("Value was either too large or too small for a UInt32"). The
    # `-as [uint32]` operator "fixes" this by returning $null instead of
    # throwing, which is worse: it silently produces an empty flag that then
    # breaks the -bor below with no error at all. Use the decimal literal,
    # which PowerShell parses as [long] and casts to [uint32] cleanly.
    $ES_CONTINUOUS      = [uint32]2147483648 # 0x80000000
    $ES_SYSTEM_REQUIRED = [uint32]1          # 0x00000001
    if ($On) {
      [SA.Native]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) | Out-Null
    } else {
      [SA.Native]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
    }
  }
}

# Invoke-Cleanup calls Set-IdleAssertion unconditionally on every exit path,
# including the restore. A stub loaded via STAYAWAKE_PLATFORM_STUB that
# omits it must not make cleanup throw before the restore runs -- that would
# be the exact "the stub is the only thing that runs" shape as the
# [uint32]0x80000000 bug that shipped and crashed the real guard on every
# Windows turn behind 173 green assertions. Fall back to a no-op so a
# missing helper can never block the restore.
if (-not (Get-Command Set-IdleAssertion -ErrorAction SilentlyContinue)) {
  function Set-IdleAssertion { param([bool]$On) }
}

$poll = 30
if ($env:STAYAWAKE_POLL) { $poll = [int]$env:STAYAWAKE_POLL }

$floor = 30
$cfg = Join-Path (Get-StateDir) 'config.json'
if (Test-Path $cfg) {
  $m = [regex]::Match((Get-Content $cfg -Raw), '"batteryFloor"\s*:\s*(\d+)')
  if ($m.Success) { $floor = [int]$m.Groups[1].Value }
}

function Test-BelowFloor {
  $p = Get-PowerSource
  return (($p.Source -eq 'battery') -and ($p.Percent -lt $floor))
}

# Checked BEFORE claiming, registering, or applying anything, so a turn
# started on a flat battery does not engage the override and release it one
# poll later.
if (Test-BelowFloor) { exit 0 }

# --- critical section 1: claim baseline + register guard, atomically ---
# Locked together so a concurrent cleanup (unregister -> count==0 -> restore)
# can never observe this guard half-registered: either both the claim and
# the registration are visible, or neither is.
#
# Get-CurrentState is called IN HERE, inside the locked scriptblock -- not
# captured into a variable before Invoke-WithStateLock is called. PowerShell
# evaluates argument expressions eagerly, same as sh's `$(...)` in an
# argument list: a value captured before the lock is acquired could already
# be stale (another session's cleanup could read/restore the live setting in
# the gap between that early read and this guard actually acquiring the
# lock), and this guard would then persist a value that was never the true
# baseline as "the baseline". That was the bug that made the macOS lid
# override permanent; the same hazard exists here if Get-CurrentState is
# hoisted out of the scriptblock.
$startupResult = Invoke-WithStateLock -MaxWaitSeconds 5 -Action {
  $cur = Get-CurrentState
  $rc = Claim-Baseline -Text $cur
  if ($rc -eq 2) { return 2 }
  Register-Guard -SessionId $SessionId -Kind $Kind -GuardPid $PID -ParentPid $ParentPid
  return 0
}

# $null means the lock itself timed out; 2 means Claim-Baseline refused to
# proceed (write failure -- nothing to restore from). Either way this guard
# must not go on to mutate power settings.
if (($null -eq $startupResult) -or ($startupResult -eq 2)) {
  [Console]::Error.WriteLine('stayawake: guard startup aborted (lock timeout or baseline claim failed)')
  exit 1
}

# --- critical section 2: unregister + reap + count + restore-if-last-out ---
# Locked together so a reaper never deletes a guard file that a resuming
# session just atomically replaced (the file it checked liveness on isn't
# the file it would delete), and so guard_count==0 is acted on before any
# other session can register in between.
#
# Cleanup gets a materially longer lock budget than startup (30s vs 5s):
# timing out unlocked here means power settings stay overridden with
# nothing left that will ever restore them, which is worse than a slow
# exit.
#
# Run-once sentinel: try/finally in PowerShell only unwinds once for a given
# exit path, so this process alone cannot double-run cleanup the way a sh
# trap re-firing on a signal-triggered `exit` can. The sentinel is kept
# anyway, to match the reference design and as defense against any future
# code path that might call Invoke-Cleanup directly in addition to the
# finally block.
$script:CleanupDone = $false
function Invoke-Cleanup {
  if ($script:CleanupDone) { return }
  $script:CleanupDone = $true

  # Runs regardless of whether the lock below succeeds -- this process's own
  # idle assertion must be released either way; it is process-local and has
  # nothing to do with the shared lock.
  Set-IdleAssertion -On $false

  $result = Invoke-WithStateLock -MaxWaitSeconds 30 -Action {
    Unregister-Guard -SessionId $SessionId -Kind $Kind
    Remove-DeadGuards
    if ((Get-GuardCount) -eq 0) {
      Invoke-RestoreState -Baseline (Read-Baseline)
      Clear-Baseline
    }
    return 0
  }

  if ($null -eq $result) {
    # Fail loudly rather than exiting 0 having abandoned the restore. Leave
    # the guard file registered -- unregistering outside the lock
    # reintroduces the very race the lock exists to prevent; the next
    # successful locker reaps it via Remove-DeadGuards.
    [Console]::Error.WriteLine("stayawake: FATAL could not acquire the state lock during cleanup for session=$SessionId kind=$Kind after 30s -- state was NOT restored and the baseline was NOT cleared. Guard file $(Get-GuardFile -SessionId $SessionId -Kind $Kind) is left registered; the next guard that successfully acquires the lock will reap this dead guard and restore automatically. If no other guard is running, restore the lid-close setting by hand.")
    exit 1
  }
}

try {
  Invoke-ApplyState
  Set-IdleAssertion -On $true

  while ($true) {
    if (-not (Test-PidAlive -ProcessId $ParentPid)) { break }
    if (-not (Test-Path (Get-GuardFile -SessionId $SessionId -Kind $Kind))) { break }
    if (Test-BelowFloor) { break }
    # Locked: an unlocked reap here could delete a guard file that a
    # resuming session just atomically replaced via its own locked
    # Register-Guard. The victim would see its own guard file vanish, break
    # out of ITS poll loop, and run cleanup while genuinely still live -- a
    # mid-turn loss of protection, not a benign tidy. The lock is held only
    # for this one call and released before Start-Sleep, so it does not
    # block other sessions for the whole poll interval -- just for one
    # mkdir/rmdir per tick. A timeout here is non-fatal: it just skips
    # reaping this cycle and retries next tick.
    Invoke-WithStateLock -MaxWaitSeconds 5 -Action { Remove-DeadGuards; return 0 } | Out-Null
    Start-Sleep -Seconds $poll
  }
}
finally {
  # finally does NOT run if this process is force-killed. That case is
  # covered by sibling guards' Remove-DeadGuards and by the logon Restore
  # task -- see the file header.
  Invoke-Cleanup
}
