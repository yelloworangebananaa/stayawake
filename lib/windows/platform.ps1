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

# Win32_Battery BatteryStatus: 1 means discharging. Everything else means
# mains power is present. A machine with no battery is always on mains.
function Get-PowerSourceFromStatus {
  param([int]$BatteryStatus, [int]$ChargePercent, [bool]$HasBattery)
  if (-not $HasBattery) {
    return [pscustomobject]@{ Source = 'ac'; Percent = 100 }
  }
  $src = 'ac'
  if ($BatteryStatus -eq 1) { $src = 'battery' }
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
