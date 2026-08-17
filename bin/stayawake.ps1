# usage: stayawake.ps1 -Verb <setup|uninstall|status|on|off|restore-if-stale> [-SessionId <id>]
#   on/off              -SessionId is the session id (default "manual").
#   restore-if-stale    -SessionId doubles as the mode selector: "force" or
#                       "boot" select those modes; any other value (including
#                       the default "manual") is normal mode. Mirrors bin/stayawake.sh,
#                       where $2 serves the same dual purpose. See
#                       Invoke-SaRestoreIfStale in lib/windows/setup.ps1.
#
# -SessionId is kept as the second parameter (positional) so that
# `stayawake.ps1 on <id>` / `off <id>` -- the calling convention
# commands/stayawake.md uses -- binds correctly. Guard files are keyed by
# session id; getting this ordering wrong scopes pins globally.
param(
  [Parameter(Position=0)]
  [ValidateSet('setup','uninstall','status','on','off','restore-if-stale')]
  [string]$Verb = 'status',

  [Parameter(Position=1)]
  [string]$SessionId = 'manual'
)

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\state.ps1')
. (Join-Path $root 'lib\windows\platform.ps1')
. (Join-Path $root 'lib\windows\setup.ps1')
. (Join-Path $root 'lib\ancestor.ps1')

switch ($Verb) {
  'setup'     { Invoke-SaSetup -Root $root }
  'uninstall' {
    # Invoke-SaUninstall returns 0/1 so a wrapper can tell a timed-out
    # revoke (still-registered admin tasks) apart from a real success --
    # see its header comment in lib/windows/setup.ps1.
    exit (Invoke-SaUninstall)
  }
  'status'    { Invoke-SaStatus }
  'restore-if-stale' {
    $mode = ''
    if (($SessionId -eq 'force') -or ($SessionId -eq 'boot')) { $mode = $SessionId }
    Invoke-SaRestoreIfStale -Mode $mode
  }
  'on' {
    $parent = Find-ClaudePid -StartPid $PID
    # Start-Process -ArgumentList (array form) does not reliably quote array
    # elements containing spaces, and this repository's own path contains
    # one (".../ryzen 9/..."). Task 9 hit this exact bug -- an unquoted path
    # element gets split at the space and the child dies before writing
    # anything, which looks exactly like a guard that silently failed to
    # start. Pre-quoting the path into its own token (same fix used in
    # bin/hook.ps1, tests/test_windows_guard.ps1, and lib/windows/setup.ps1's
    # elevated relaunch) sidesteps that.
    $guardQ = '"' + (Join-Path $root 'bin\guard.ps1') + '"'
    Start-Process powershell -WindowStyle Hidden -ArgumentList `
      '-NoProfile','-ExecutionPolicy','Bypass','-File',$guardQ,
      '-SessionId',$SessionId,'-Kind','pin','-ParentPid',$parent | Out-Null
    Write-Host 'stayawake: pinned on for this session.'
  }
  'off' {
    Unregister-Guard -SessionId $SessionId -Kind 'pin'
    Write-Host 'stayawake: pin released.'
  }
}
