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
  New-Item -ItemType Directory -Force -Path (Get-GuardsDir) -ErrorAction Stop | Out-Null
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
    if (Test-Path (Get-BaselineFile)) { return 1 }
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

function Clear-Baseline {
  $f = Get-BaselineFile
  if (Test-Path $f) { Remove-Item $f -Force }
}

# Writes to a temp file in the SAME directory as the destination, then
# Move-Item -Force's it into place. On NTFS, Move-Item -Force onto an
# existing/absent destination maps to MoveFileEx with
# MOVEFILE_REPLACE_EXISTING, which is atomic -- a guard file is never
# observable mid-write. A force-kill between the write and the move just
# leaves an orphan temp file, never a truncated/unparseable guard.
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
  $dest = Get-GuardFile -SessionId $SessionId -Kind $Kind
  $tmp = Join-Path (Get-GuardsDir) ".tmp-$SessionId-$Kind-$PID"
  Set-Content -Path $tmp -Value "guard_pid=$GuardPid`nparent_pid=$ParentPid" -Encoding utf8
  Move-Item -Path $tmp -Destination $dest -Force
}

function Unregister-Guard {
  param([string]$SessionId, [string]$Kind)
  $f = Get-GuardFile -SessionId $SessionId -Kind $Kind
  if (Test-Path $f) { Remove-Item $f -Force }
}

function Get-GuardCount {
  $d = Get-GuardsDir
  if (-not (Test-Path $d)) { return 0 }
  return @(Get-ChildItem -Path $d -File | Where-Object { $_.Name -notlike '.tmp-*' }).Count
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
  foreach ($f in Get-ChildItem -Path $d -File | Where-Object { $_.Name -notlike '.tmp-*' }) {
    $m = [regex]::Match((Get-Content $f.FullName -Raw), 'guard_pid=(\d+)')
    if (-not $m.Success) { continue }
    if (-not (Test-PidAlive -ProcessId ([int]$m.Groups[1].Value))) {
      Remove-Item $f.FullName -Force
    }
  }
}
