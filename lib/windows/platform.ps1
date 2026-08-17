# Windows power platform module. Dot-sourced, not executed. PowerShell 5.1 safe.

function ConvertFrom-PowercfgHex {
  param([string]$Hex)
  return [Convert]::ToInt32($Hex.Substring(2), 16)
}

# Parses `powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION` output.
# Present is $false when the machine exposes no lid close action at all.
function Get-LidActionFromText {
  param([string]$Text)
  if ($Text -notmatch 'LIDACTION') {
    return [pscustomobject]@{ Ac = 0; Dc = 0; Present = $false }
  }
  $ac = [regex]::Match($Text, 'Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)')
  $dc = [regex]::Match($Text, 'Current DC Power Setting Index:\s*(0x[0-9a-fA-F]+)')
  if (-not $ac.Success -or -not $dc.Success) {
    return [pscustomobject]@{ Ac = 0; Dc = 0; Present = $false }
  }
  return [pscustomobject]@{
    Ac      = ConvertFrom-PowercfgHex -Hex $ac.Groups[1].Value
    Dc      = ConvertFrom-PowercfgHex -Hex $dc.Groups[1].Value
    Present = $true
  }
}

# Win32_Battery BatteryStatus: 1 = Discharging, 4 = Low (discharging), 5 =
# Critical (discharging) all mean "on battery". 2 = AC, 3 = Fully charged,
# 6-9 = Charging (various), 10 = Undefined, 11 = Partially charged all mean
# mains power is present. A machine with no battery is always on mains.
#
# Where this mapping is ambiguous, err toward 'battery': that direction
# releases the lid override and lets the machine sleep, which is the safe
# failure. Erring toward 'ac' keeps a machine awake that should have been
# allowed to sleep (and, worse, disables the battery-floor safety valve on
# exactly the low/critical statuses it exists to catch). Do not "simplify"
# this back to a single discharging value.
function Get-PowerSourceFromStatus {
  param([int]$BatteryStatus, [int]$ChargePercent, [bool]$HasBattery)
  if (-not $HasBattery) {
    return [pscustomobject]@{ Source = 'ac'; Percent = 100 }
  }
  $src = 'ac'
  if ($BatteryStatus -eq 1 -or $BatteryStatus -eq 4 -or $BatteryStatus -eq 5) { $src = 'battery' }
  return [pscustomobject]@{ Source = $src; Percent = $ChargePercent }
}

# Parses `powercfg /a`. True when the machine offers S0 Low Power Idle but not
# S3, meaning lid close is firmware-driven and LIDACTION may not be honoured.
function Test-ModernStandbyFromText {
  param([string]$Text)
  $available = [regex]::Match($Text, '(?s)available on this system:(.*?)(?:\r?\n\r?\n|$)')
  if (-not $available.Success) { return $false }
  $block = $available.Groups[1].Value
  $hasS0 = $block -match 'S0 Low Power Idle'
  $hasS3 = $block -match 'Standby \(S3\)'
  return ($hasS0 -and -not $hasS3)
}

# --- live system access (not unit tested; the parsers above are) ---

$script:SubButtons = '4f971e89-eebd-4455-a8de-9e59040e7347'
$script:LidAction  = '5ca83367-6e45-459f-a27b-476b1d01c936'

function Get-LidActionLive {
  $text = (powercfg /query SCHEME_CURRENT $script:SubButtons $script:LidAction 2>&1 | Out-String)
  return Get-LidActionFromText -Text $text
}

function Get-CurrentState {
  $lid = Get-LidActionLive
  if (-not $lid.Present) { return 'lidAc=-1;lidDc=-1' }
  return "lidAc=$($lid.Ac);lidDc=$($lid.Dc)"
}

function Get-PowerSource {
  $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $b) {
    return Get-PowerSourceFromStatus -BatteryStatus 0 -ChargePercent 0 -HasBattery $false
  }
  return Get-PowerSourceFromStatus -BatteryStatus ([int]$b.BatteryStatus) `
                                   -ChargePercent ([int]$b.EstimatedChargeRemaining) `
                                   -HasBattery $true
}

# The guard is unprivileged; the elevated scheduled tasks do the actual writes.
#
# Fix 4: `schtasks /run` is fire-and-forget -- a zero exit only means the run
# was QUEUED, never that the elevated task actually finished (see
# Wait-SaRestoreTaskComplete in lib/windows/setup.ps1 for the one place that
# already accounts for this). So a zero exit here is not proof of anything
# and must not be oversold. A NON-zero exit, though, means schtasks refused
# to even queue the run -- e.g. the task was uninstalled while a guard is
# still live -- and that silent no-op is worth surfacing. Warn to stderr and
# keep going; a guard mid-cleanup must still complete its remaining teardown,
# so this never throws.
function Invoke-ApplyState {
  schtasks /run /tn "StayAwake\Disable" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("stayawake: WARNING -- schtasks could not queue StayAwake\Disable (exit $LASTEXITCODE); lid override may not have been applied.")
  }
}

function Invoke-RestoreState {
  param([string]$Baseline)
  Set-Content -Path (Join-Path (Get-StateDir) 'restore.state') -Value $Baseline -Encoding utf8
  schtasks /run /tn "StayAwake\Restore" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("stayawake: WARNING -- schtasks could not queue StayAwake\Restore (exit $LASTEXITCODE); lid setting may not have been restored.")
  }
}
