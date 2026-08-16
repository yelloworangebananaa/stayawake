# usage: hook.ps1 -Event <UserPromptSubmit|Stop|SessionEnd>
# Reads the hook payload on stdin, extracts session_id, and starts or stops a
# guard. Registered unconditionally alongside the sh command form in
# hooks/hooks.json (see docs/hook-dispatch.md) -- the OS guard below is what
# makes this a no-op everywhere except Windows. Both command forms fire on
# this dev machine (Git Bash puts sh on PATH), so without this guard every
# turn would spawn two guards and the refcount would be wrong from the first
# prompt.
param([ValidateSet('UserPromptSubmit','Stop','SessionEnd')][string]$Event)

if ($env:OS -ne 'Windows_NT') { exit 0 }

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\state.ps1')
. (Join-Path $root 'lib\ancestor.ps1')

$payload = [Console]::In.ReadToEnd()
$session = 'unknown'
try {
  $obj = $payload | ConvertFrom-Json
  if ($obj.session_id) { $session = [string]$obj.session_id }
} catch {
  # A malformed payload must never block the turn. Fall through with 'unknown'.
}

switch ($Event) {
  'UserPromptSubmit' {
    # Find-ClaudePid walks past this short-lived hook process to the actual
    # Claude Code process -- a guard watching the hook's own pid would see
    # its parent exit almost immediately and drop protection mid-turn.
    $parent = Find-ClaudePid -StartPid $PID
    $guard = Join-Path $root 'bin\guard.ps1'
    # Start-Process -ArgumentList (array form) does not reliably quote array
    # elements containing spaces, and this repository's own path contains
    # one (".../ryzen 9/..."). Task 9 hit this exact bug -- an unquoted path
    # element gets split at the space and the child dies before writing
    # anything, which looks exactly like a guard that silently failed to
    # start. Pre-quoting the path into its own token (same fix used in
    # tests/test_windows_guard.ps1 and lib/windows/setup.ps1's elevated
    # relaunch) sidesteps that.
    $guardQ = '"' + $guard + '"'
    # Detached (-WindowStyle Hidden, no -Wait) so this hook returns
    # immediately; a hook that blocks on the guard adds latency to every
    # prompt submission.
    Start-Process powershell -WindowStyle Hidden -ArgumentList `
      '-NoProfile','-ExecutionPolicy','Bypass','-File',$guardQ,
      '-SessionId',$session,'-Kind','turn','-ParentPid',$parent | Out-Null
  }
  'Stop' {
    Unregister-Guard -SessionId $session -Kind 'turn'
  }
  'SessionEnd' {
    Unregister-Guard -SessionId $session -Kind 'turn'
    Unregister-Guard -SessionId $session -Kind 'pin'
  }
}
exit 0
