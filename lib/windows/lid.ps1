# Runs elevated, launched only by the StayAwake scheduled tasks.
# Disable: set lid close action to "do nothing" on both AC and battery.
# Restore: write back the values recorded in restore.state, or Sleep(1) if absent.
# -1 in either baseline field means "this machine has no lid-close setting" --
# skip writing that field rather than write a value to a setting that does
# not exist.
param([ValidateSet('Disable','Restore')][string]$Action)

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'lib\state.ps1')
. (Join-Path $root 'lib\windows\platform.ps1')

$sub = '4f971e89-eebd-4455-a8de-9e59040e7347'
$lid = '5ca83367-6e45-459f-a27b-476b1d01c936'

function Set-LidAction {
  param([int]$Ac, [int]$Dc)
  if ($Ac -ge 0) { powercfg /setacvalueindex SCHEME_CURRENT $sub $lid $Ac | Out-Null }
  if ($Dc -ge 0) { powercfg /setdcvalueindex SCHEME_CURRENT $sub $lid $Dc | Out-Null }
  powercfg /setactive SCHEME_CURRENT | Out-Null
}

if ($Action -eq 'Disable') {
  $cur = Get-LidActionLive
  if (-not $cur.Present) { exit 0 }
  Set-LidAction -Ac 0 -Dc 0
  exit 0
}

# Restore. Default to 1 (Sleep) rather than -1 (skip) if restore.state is
# missing or unparseable: this is the error path, not the "machine has no
# lid setting" path, and defaulting to skip would leave the lid-close
# override applied forever -- exactly the permanent-no-sleep catastrophe
# this project exists to prevent. -1 is reserved for values actually read
# back from a baseline that recorded "no lid setting present" (Get-CurrentState
# returns lidAc=-1;lidDc=-1 in that case), never for "we couldn't read it".
$file = Join-Path (Get-StateDir) 'restore.state'
$ac = 1; $dc = 1
if (Test-Path $file) {
  $text = (Get-Content $file -Raw)
  $m = [regex]::Match($text, 'lidAc=(-?\d+);lidDc=(-?\d+)')
  if ($m.Success) { $ac = [int]$m.Groups[1].Value; $dc = [int]$m.Groups[2].Value }
}
Set-LidAction -Ac $ac -Dc $dc
exit 0
