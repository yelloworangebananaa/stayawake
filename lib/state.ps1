# Shared state for stayawake guards. Dot-sourced, not executed.
#
# Windows twin of lib/state.sh -- must keep identical contracts. See that
# file's header comments for the full rationale; only Windows-specific
# deltas are repeated here.

function Get-StateDir {
  if ($env:STAYAWAKE_HOME) { return $env:STAYAWAKE_HOME }
  return (Join-Path $env:USERPROFILE '.stayawake')
}

function Get-GuardsDir { return (Join-Path (Get-StateDir) 'guards') }

function Get-GuardFile {
  param([string]$SessionId, [string]$Kind)
  return (Join-Path (Get-GuardsDir) "$SessionId-$Kind")
}

function Get-BaselineFile { return (Join-Path (Get-StateDir) 'original.state') }

function Initialize-StateDirs {
  # New-Item -Force silently no-ops when the target path already exists as a
  # non-directory item -- it does NOT throw, so -ErrorAction Stop alone never
  # catches "guards" existing as a regular file. Verify the result is actually
  # a directory and throw ourselves; the caller's catch turns that into a 2.
  New-Item -ItemType Directory -Force -Path (Get-GuardsDir) -ErrorAction Stop | Out-Null
  if (-not (Test-Path -Path (Get-GuardsDir) -PathType Container)) {
    throw "guards path exists and is not a directory: $(Get-GuardsDir)"
  }
}

# CreateNew throws IOException when the file exists. That throw is the atomic
# test-and-set; do not replace it with a Test-Path check, which races.
#
# Return contract (mirrors claim_baseline() in lib/state.sh exactly --
# callers in later tasks depend on this):
#   0 = this call created the baseline. Caller captured it, safe to proceed.
#   1 = baseline already existed. Another session owns it, safe to proceed.
#   2 = the write failed for a reason OTHER than "already exists" (unwritable
#       dir, disk full, directory creation failure, ...). No baseline was
#       written. Caller MUST NOT proceed to mutate power settings on 2 --
#       there would be nothing to restore from.
function Claim-Baseline {
  param([string]$Text)
  try {
    Initialize-StateDirs
  } catch {
    return 2
  }
  try {
    $fs = [System.IO.File]::Open((Get-BaselineFile), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
  } catch [System.IO.IOException] {
    # Length -gt 0 (exists and non-empty) rather than a bare Test-Path: an
    # existing-but-empty baseline is a partial write (create succeeded, data
    # write didn't) and must be treated as a failed claim, not a valid one to
    # proceed from. Mirrors sh's `[ -s ... ]` in claim_baseline().
    $existing = Get-Item (Get-BaselineFile) -ErrorAction SilentlyContinue
    if ($existing -and $existing.Length -gt 0) { return 1 }
    return 2
  } catch {
    return 2
  }
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $fs.Write($bytes, 0, $bytes.Length)
  } finally {
    $fs.Dispose()
  }
  return 0
}

function Read-Baseline {
  $f = Get-BaselineFile
  if (-not (Test-Path $f)) { return '' }
  return ([System.IO.File]::ReadAllText($f)).Trim()
}

# STAYAWAKE_HOME is a caller-supplied override and can point anywhere,
# including under a %TEMP% that Windows expanded to its 8.3 short-name form
# (this happens whenever the profile directory name contains a space, e.g.
# "RYZEN9~1" for "ryzen 9" -- a completely normal, common Windows setup).
# Test-Path/New-Item/Get-ChildItem/Get-Item all resolve such paths fine, but
# Move-Item and Remove-Item do not -- they throw PSArgumentException
# "An object at the specified path ... does not exist" on the literal short
# form even though the target is real. Get-Item resolves it once; every
# provider-cmdlet call in this file that touches a caller-derived path goes
# through a value returned by Get-Item/Get-ChildItem, never the raw one.
function Clear-Baseline {
  $f = Get-BaselineFile
  if (Test-Path $f) {
    # Get-Item is inside the try too: if the file vanishes between Test-Path
    # and here (a concurrent Clear-Baseline), Get-Item throws the same
    # ItemNotFoundException that Remove-Item would. Delete is idempotent --
    # "already gone" is the desired end state, not a failure -- so only that
    # one exception type is swallowed. Any other failure (permissions, disk)
    # still throws loud, same as everywhere else in this file.
    try {
      Remove-Item (Get-Item $f).FullName -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
    }
  }
}

# Writes to a temp file in the SAME directory as the destination, then
# Move-Item -Force's it into place. The fresh-create case (no prior file at
# $dest) is the atomic test-and-set that matters for crash safety: a
# force-kill between the write and the move leaves an orphan temp file,
# never a truncated/unparseable guard, because the destination is never
# written in place. The re-register/overwrite case (a guard file for the
# same session+kind already exists) is not guaranteed atomic the way POSIX
# rename(2) is -- Windows PowerShell 5.1's Move-Item -Force may fall back to
# delete-then-move when the destination exists. That's still crash-safe in
# the same sense (destination is either the old full file, momentarily
# absent, or the new full file -- never partial); it just isn't a single
# atomic syscall. -ErrorAction Stop makes any failure here (including the
# short-path trap above) a loud exception instead of a silently-swallowed
# non-terminating error.
#
# The temp lives in the same directory on purpose: a temp elsewhere would
# make the move a cross-volume copy, which is not atomic.
#
# Unlike the sh twin, Windows has no dotfile convention -- Get-ChildItem
# -File returns ".tmp-*" files normally, it does not skip them the way a
# POSIX "*" glob skips dotfiles. Get-GuardCount and Remove-DeadGuards MUST
# explicitly exclude the ".tmp-*" prefix, or an in-flight temp file gets
# miscounted as a guard and the refcount bug is reintroduced.
function Register-Guard {
  param([string]$SessionId, [string]$Kind, [int]$GuardPid, [int]$ParentPid)
  Initialize-StateDirs
  $guardsDirLong = (Get-Item (Get-GuardsDir)).FullName
  $dest = Join-Path $guardsDirLong "$SessionId-$Kind"
  $tmp = Join-Path $guardsDirLong ".tmp-$SessionId-$Kind-$PID"
  Set-Content -Path $tmp -Value "guard_pid=$GuardPid`nparent_pid=$ParentPid" -Encoding utf8 -ErrorAction Stop
  Move-Item -Path $tmp -Destination $dest -Force -ErrorAction Stop
}

function Unregister-Guard {
  param([string]$SessionId, [string]$Kind)
  $f = Get-GuardFile -SessionId $SessionId -Kind $Kind
  if (Test-Path $f) {
    # Same idempotent-delete reasoning as Clear-Baseline: a concurrent
    # Remove-DeadGuards could reap this exact file between Test-Path and
    # here. Get-Item is inside the try for the same reason -- it can throw
    # ItemNotFoundException too if the file is already gone by then.
    try {
      Remove-Item (Get-Item $f).FullName -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
    }
  }
}

function Get-GuardCount {
  $d = Get-GuardsDir
  if (-not (Test-Path $d)) { return 0 }
  # Correction 2: exclude '.stale.*' the same way '.tmp-*' is excluded above.
  # The lock's break target (Invoke-WithStateLock, below) normally lives next
  # to "guards", not inside it, but Windows has no dotfile convention -- a
  # ".stale.*" entry anywhere Get-ChildItem -File can see it would otherwise
  # be miscounted as a live guard and reintroduce the refcount bug.
  return @(Get-ChildItem -Path $d -File | Where-Object { $_.Name -notlike '.tmp-*' -and $_.Name -notlike '.stale.*' }).Count
}

function Test-PidAlive {
  param([int]$ProcessId)
  $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  return ($null -ne $p)
}

# ponytail: PID reuse could keep a stale guard file alive for one poll cycle.
# Accepted; the cost is bounded and the fix would need a start-time comparison.
#
# Temp files (".tmp-*") are skipped, not deleted -- they are never even
# examined for a guard_pid= line. This is Correction 2's exclusion, not
# Correction 3's defence.
#
# The "no parseable PID -> skip it" branch below is defence-in-depth, not a
# live path: Register-Guard's atomic rename means any non-temp file matched
# here was already fully written before it became visible. Do NOT change
# this to delete unparseable files -- another session's Remove-DeadGuards
# could observe a live guard file mid-write (pre-rename it's a temp, so this
# is about theoretical corruption) and deleting it would trigger a premature
# restore while that session is still working. Skip beats delete here.
function Remove-DeadGuards {
  $d = Get-GuardsDir
  if (-not (Test-Path $d)) { return }
  foreach ($f in Get-ChildItem -Path $d -File | Where-Object { $_.Name -notlike '.tmp-*' -and $_.Name -notlike '.stale.*' }) {
    # A zero-byte (or otherwise unreadable) file is the canonical unparseable
    # guard file. Get-Content -Raw returns $null for an empty file, and
    # [regex]::Match($null, ...) throws MethodInvocationException rather than
    # just failing to match -- that would abort the whole loop and leave
    # every remaining guard un-reaped. Treat "nothing read" as "skip it",
    # same as sh's empty-var + continue.
    $raw = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { continue }
    # Anchored (and multiline) so a malformed line like "guard_pid=12abc"
    # is skipped, not parsed as PID 12 -- matches sh's
    # '^guard_pid=\([0-9][0-9]*\)$' instead of matching anywhere in the file.
    $m = [regex]::Match($raw, '(?m)^guard_pid=(\d+)\r?$')
    if (-not $m.Success) { continue }
    if (-not (Test-PidAlive -ProcessId ([int]$m.Groups[1].Value))) {
      # Two sessions' Remove-DeadGuards can both enumerate the same dead-PID
      # file and both try to remove it; this session's own exit-time
      # Unregister-Guard can race a concurrent reap of the same file. Delete
      # is idempotent -- swallow only "already gone" so this one entry
      # doesn't abort the foreach and strand every other dead guard in the
      # batch un-reaped. $f is already a FileInfo from Get-ChildItem, so no
      # second Get-Item lookup is needed here.
      try {
        Remove-Item $f.FullName -Force -ErrorAction Stop
      } catch [System.Management.Automation.ItemNotFoundException] {
      }
    }
  }
}

function Get-LockDir { return (Join-Path (Get-StateDir) 'lock') }

# Windows twin of with_state_lock() in lib/state.sh -- see that function's
# header comment for the full rationale. Serializes the guard's two critical
# sections (startup claim+register, cleanup unregister+reap+restore) across
# processes so the read-then-act sequences over guard files and the baseline
# can never interleave. Only Windows-specific deltas are called out below.
#
# A directory is the mutex: New-Item -ItemType Directory -ErrorAction Stop
# throws when the target already exists, which is the atomic test-and-set
# (the same guarantee POSIX mkdir gives the sh twin). A Test-Path-then-create
# sequence would race and must never replace it.
#
# Stale-lock recovery is mandatory, not optional -- a guard force-killed
# while holding the lock must not wedge every future session forever (that
# is the expected case here, not the exotic one). If the lock is held and
# its recorded pid is not alive, break it by renaming the lock dir to a
# private per-process name ([System.IO.Directory]::Move), then deleting the
# renamed copy. Only one racer's rename can succeed -- the source vanishes
# for everyone else the instant it wins -- which was verified experimentally
# against NTFS before this was relied on (see task-9-report.md). A failed
# rename means someone else already broke this lock instance first: fall
# through and retry, and never fall back to deleting by the shared path --
# that is exactly the two-winner bug the sh twin's history warns against
# (two waiters both judging the same dead pid stale and both rm -rf'ing the
# same path, the second hitting a lock a third process legitimately
# recreated there).
#
# Ownership is verified both right after acquiring (in case our own
# just-created lock was broken as stale before we finished stamping our pid
# into it) and again before releasing (in case it was broken out from under
# us while held, e.g. we looked dead to a waiter and got reaped by
# mistake). Never remove a lock whose pid file doesn't hold our own pid --
# it belongs to someone else now.
#
# Returns $null if the lock could not be acquired within MaxWaitSeconds --
# callers MUST treat that as "the action did not run", never as success, and
# fail loudly rather than proceeding unlocked. Otherwise returns whatever
# $Action returned.
function Invoke-WithStateLock {
  param(
    [Parameter(Mandatory=$true)][scriptblock]$Action,
    [int]$MaxWaitSeconds = 5
  )
  try { Initialize-StateDirs } catch { return $null }
  $lockDir = Get-LockDir
  $pidFile = Join-Path $lockDir 'pid'
  $waited = 0

  while ($true) {
    $created = $false
    try {
      New-Item -ItemType Directory -Path $lockDir -ErrorAction Stop | Out-Null
      $created = $true
    } catch {
      $created = $false
    }

    if ($created) {
      try { Set-Content -Path $pidFile -Value $PID -Encoding utf8 -ErrorAction Stop } catch {}
      $readBack = $null
      try { $readBack = (Get-Content -Path $pidFile -Raw -ErrorAction Stop).Trim() } catch {}
      if ($readBack -eq "$PID") { break }
      # Someone broke our just-created lock before we could stamp our own
      # pid into it (or the write/read itself failed). Do not assume
      # ownership -- retry from the top rather than proceeding.
      continue
    }

    # Lock already held by someone else -- inspect the recorded holder.
    $holder = $null
    try { $holder = (Get-Content -Path $pidFile -Raw -ErrorAction Stop).Trim() } catch {}
    $holderPid = 0
    $holderParsed = $holder -and [int]::TryParse($holder, [ref]$holderPid)
    if ($holderParsed -and -not (Test-PidAlive -ProcessId $holderPid)) {
      $staleTarget = "$lockDir.stale.$PID"
      $renamed = $false
      try {
        [System.IO.Directory]::Move($lockDir, $staleTarget)
        $renamed = $true
      } catch {
        $renamed = $false
      }
      if ($renamed) {
        Remove-Item -Path $staleTarget -Recurse -Force -ErrorAction SilentlyContinue
      }
      continue
    }

    if ($waited -ge $MaxWaitSeconds) {
      [Console]::Error.WriteLine("stayawake: timed out waiting for state lock ($lockDir)")
      return $null
    }
    Start-Sleep -Seconds 1
    $waited++
  }

  try {
    return (& $Action)
  } finally {
    $holder = $null
    try { $holder = (Get-Content -Path $pidFile -Raw -ErrorAction SilentlyContinue).Trim() } catch {}
    if ($holder -eq "$PID") {
      Remove-Item -Path $lockDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
