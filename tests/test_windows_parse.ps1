$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'assert.ps1')
. (Join-Path $here '..\lib\windows\platform.ps1')

$lid = Get-LidActionFromText -Text (Get-Content (Join-Path $here 'fixtures\powercfg-lidaction.txt') -Raw)
Assert-Eq -Actual $lid.Present -Expected $true -Name 'lid setting detected as present'
Assert-Eq -Actual $lid.Ac -Expected 1 -Name 'AC lid action parsed as 1'
Assert-Eq -Actual $lid.Dc -Expected 1 -Name 'DC lid action parsed as 1'

$none = Get-LidActionFromText -Text (Get-Content (Join-Path $here 'fixtures\powercfg-no-lidaction.txt') -Raw)
Assert-Eq -Actual $none.Present -Expected $false -Name 'absent lid setting reported as absent'

$ac = Get-PowerSourceFromStatus -BatteryStatus 2 -ChargePercent 100 -HasBattery $true
Assert-Eq -Actual $ac.Source -Expected 'ac' -Name 'BatteryStatus 2 is AC'

$bat = Get-PowerSourceFromStatus -BatteryStatus 1 -ChargePercent 23 -HasBattery $true
Assert-Eq -Actual $bat.Source -Expected 'battery' -Name 'BatteryStatus 1 is battery'
Assert-Eq -Actual $bat.Percent -Expected 23 -Name 'charge percent passed through'

$desk = Get-PowerSourceFromStatus -BatteryStatus 0 -ChargePercent 0 -HasBattery $false
Assert-Eq -Actual $desk.Source -Expected 'ac' -Name 'no battery means AC'
Assert-Eq -Actual $desk.Percent -Expected 100 -Name 'no battery reports 100 percent'

$s3 = Test-ModernStandbyFromText -Text (Get-Content (Join-Path $here 'fixtures\powercfg-a-s3.txt') -Raw)
Assert-Eq -Actual $s3 -Expected $false -Name 'S3 machine is not modern standby'

$s0 = Test-ModernStandbyFromText -Text (Get-Content (Join-Path $here 'fixtures\powercfg-a-s0.txt') -Raw)
Assert-Eq -Actual $s0 -Expected $true -Name 'S0ix-only machine is modern standby'

Complete-Tests
