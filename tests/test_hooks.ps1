$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'assert.ps1')
$root = Split-Path -Parent $here
$hook = Join-Path $root 'bin\hook.ps1'

$tempDir = (Get-Item $env:TEMP).FullName
$env:STAYAWAKE_HOME = Join-Path $tempDir "stayawake-hooktest-$PID"
if (Test-Path $env:STAYAWAKE_HOME) { Remove-Item $env:STAYAWAKE_HOME -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $env:STAYAWAKE_HOME 'guards') | Out-Null

function Set-Guard {
  param([string]$Session, [string]$Kind)
  $f = Join-Path (Join-Path $env:STAYAWAKE_HOME 'guards') "$Session-$Kind"
  Set-Content -Path $f -Value "guard_pid=$PID`nparent_pid=$PID" -Encoding utf8
}
function Test-GuardExists {
  param([string]$Session, [string]$Kind)
  $f = Join-Path (Join-Path $env:STAYAWAKE_HOME 'guards') "$Session-$Kind"
  if (Test-Path $f) { return 'yes' }
  return 'no'
}
function Clear-Guards {
  Get-ChildItem (Join-Path $env:STAYAWAKE_HOME 'guards') -File -ErrorAction SilentlyContinue | Remove-Item -Force
}
function Invoke-Hook {
  param([string]$Payload, [string]$Event, [string]$HookPath = $hook)
  $Payload | & powershell -NoProfile -ExecutionPolicy Bypass -File $HookPath -HookEvent $Event
  return $LASTEXITCODE
}

# --- Stop removes only the turn guard file ---
Set-Guard -Session 'sess-a' -Kind 'turn'
Set-Guard -Session 'sess-a' -Kind 'pin'
$rc = Invoke-Hook -Payload '{"session_id":"sess-a","hook_event_name":"Stop"}' -Event 'Stop'
Assert-Eq -Actual $rc -Expected 0 -Name 'Stop: hook exits 0'
Assert-Eq -Actual (Test-GuardExists 'sess-a' 'turn') -Expected 'no' -Name 'Stop: turn guard removed'
Assert-Eq -Actual (Test-GuardExists 'sess-a' 'pin') -Expected 'yes' -Name 'Stop: pin guard survives'
Clear-Guards

# --- SessionEnd removes both ---
Set-Guard -Session 'sess-b' -Kind 'turn'
Set-Guard -Session 'sess-b' -Kind 'pin'
$rc = Invoke-Hook -Payload '{"session_id":"sess-b","hook_event_name":"SessionEnd"}' -Event 'SessionEnd'
Assert-Eq -Actual $rc -Expected 0 -Name 'SessionEnd: hook exits 0'
Assert-Eq -Actual (Test-GuardExists 'sess-b' 'turn') -Expected 'no' -Name 'SessionEnd: turn guard removed'
Assert-Eq -Actual (Test-GuardExists 'sess-b' 'pin') -Expected 'no' -Name 'SessionEnd: pin guard removed'
Clear-Guards

# --- malformed / missing payload falls back to session 'unknown', never
# aborts the turn. Each case unregisters the 'unknown' guard(s), which is
# the only externally-observable proof the fallback ran instead of the hook
# dying/blocking on bad input. ---
Set-Guard -Session 'unknown' -Kind 'turn'
Set-Guard -Session 'unknown' -Kind 'pin'
$rc = Invoke-Hook -Payload '' -Event 'SessionEnd'
Assert-Eq -Actual $rc -Expected 0 -Name 'empty stdin: hook still exits 0'
Assert-Eq -Actual (Test-GuardExists 'unknown' 'turn') -Expected 'no' -Name "empty stdin: falls back to 'unknown' and unregisters it"
Assert-Eq -Actual (Test-GuardExists 'unknown' 'pin') -Expected 'no' -Name "empty stdin: pin for 'unknown' also removed"

Set-Guard -Session 'unknown' -Kind 'turn'
$rc = Invoke-Hook -Payload '{not valid json at all' -Event 'Stop'
Assert-Eq -Actual $rc -Expected 0 -Name 'malformed JSON: hook still exits 0'
Assert-Eq -Actual (Test-GuardExists 'unknown' 'turn') -Expected 'no' -Name "malformed JSON: falls back to 'unknown' rather than aborting"

Set-Guard -Session 'unknown' -Kind 'turn'
$rc = Invoke-Hook -Payload '{"hook_event_name":"Stop"}' -Event 'Stop'
Assert-Eq -Actual $rc -Expected 0 -Name 'JSON missing session_id: hook still exits 0'
Assert-Eq -Actual (Test-GuardExists 'unknown' 'turn') -Expected 'no' -Name "JSON missing session_id: falls back to 'unknown'"
Clear-Guards

# --- platform gate holds: the real ambient $env:OS is Windows_NT, so fake a
# non-Windows value for the CHILD process only (set it right before spawning,
# restore in a finally right after -- our own process's env is never left
# mutated). The hook must be a total no-op for every event: it must not
# touch guard files at all, let alone the wrong one. ---
Set-Guard -Session 'sess-gate' -Kind 'turn'
Set-Guard -Session 'sess-gate' -Kind 'pin'
$savedOS = $env:OS
$env:OS = 'NotWindows'
try {
  $rc = Invoke-Hook -Payload '{"session_id":"sess-gate","hook_event_name":"Stop"}' -Event 'Stop'
} finally {
  $env:OS = $savedOS
}
Assert-Eq -Actual $rc -Expected 0 -Name 'wrong platform: Stop hook still exits 0'
Assert-Eq -Actual (Test-GuardExists 'sess-gate' 'turn') -Expected 'yes' -Name 'wrong platform: Stop must NOT remove the turn guard'

$env:OS = 'NotWindows'
try {
  $rc = Invoke-Hook -Payload '{"session_id":"sess-gate","hook_event_name":"SessionEnd"}' -Event 'SessionEnd'
} finally {
  $env:OS = $savedOS
}
Assert-Eq -Actual $rc -Expected 0 -Name 'wrong platform: SessionEnd hook still exits 0'
Assert-Eq -Actual (Test-GuardExists 'sess-gate' 'turn') -Expected 'yes' -Name 'wrong platform: SessionEnd must NOT remove the turn guard'
Assert-Eq -Actual (Test-GuardExists 'sess-gate' 'pin') -Expected 'yes' -Name 'wrong platform: SessionEnd must NOT remove the pin guard'
Clear-Guards

# --- UserPromptSubmit dispatch decision, without ever spawning a real guard ---
# A real bin/guard.ps1 holds a live idle assertion and polls forever; starting
# it from a test would leak a background process (this machine's own known
# hazard: orphaned guards plus fast Windows PID reuse causing confusing
# cross-run failures later). Instead: copy hook.ps1 + the real lib it dot-
# sources into a scratch tree, and replace ONLY guard.ps1 with an inert stub
# that records its argv and exits immediately. hook.ps1's own $root
# computation (Split-Path -Parent $PSScriptRoot) points bin\guard.ps1 at this
# scratch copy, so the real UserPromptSubmit branch (Find-ClaudePid,
# Start-Process, argv construction) runs for real -- it just can't reach a
# real guard. The real ambient platform here already IS Windows, so this
# single run also proves the gate takes the spawn branch on the right
# platform (the wrong-platform case is covered by the Stop/SessionEnd gate
# test above, which shares the same gate line).
$hooktree = Join-Path $env:STAYAWAKE_HOME 'hooktree'
New-Item -ItemType Directory -Force -Path (Join-Path $hooktree 'bin') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $hooktree 'lib') | Out-Null
Copy-Item (Join-Path $root 'bin\hook.ps1') (Join-Path $hooktree 'bin\hook.ps1')
Copy-Item (Join-Path $root 'lib\state.ps1') (Join-Path $hooktree 'lib\state.ps1')
Copy-Item (Join-Path $root 'lib\ancestor.ps1') (Join-Path $hooktree 'lib\ancestor.ps1')
@'
param([string]$SessionId,[string]$Kind,[int]$ParentPid)
$marker = Join-Path $env:STAYAWAKE_HOME 'dispatch-marker.txt'
"session=$SessionId kind=$Kind parent=$ParentPid" | Set-Content -Path $marker -Encoding utf8
'@ | Set-Content -Path (Join-Path $hooktree 'bin\guard.ps1') -Encoding utf8

$markerPath = Join-Path $env:STAYAWAKE_HOME 'dispatch-marker.txt'
$rc = Invoke-Hook -Payload '{"session_id":"sess-ups","hook_event_name":"UserPromptSubmit"}' `
                   -Event 'UserPromptSubmit' -HookPath (Join-Path $hooktree 'bin\hook.ps1')
Assert-Eq -Actual $rc -Expected 0 -Name 'UserPromptSubmit dispatch: hook exits 0 immediately (detached)'
$deadline = (Get-Date).AddSeconds(10)
while (((Get-Date) -lt $deadline) -and -not (Test-Path $markerPath)) { Start-Sleep -Milliseconds 200 }
$content = ''
if (Test-Path $markerPath) { $content = Get-Content $markerPath -Raw }
Assert-Eq -Actual ($content -match 'session=sess-ups') -Expected $true -Name 'UserPromptSubmit dispatch: guard invoked for the right session'
Assert-Eq -Actual ($content -match 'kind=turn') -Expected $true -Name 'UserPromptSubmit dispatch: guard invoked with kind=turn'
Remove-Item $markerPath -Force -ErrorAction SilentlyContinue

Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
