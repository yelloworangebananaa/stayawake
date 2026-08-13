$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'assert.ps1')
. (Join-Path $here '..\lib\ancestor.ps1')

$tree = @{ 100 = @{ Parent = 200; Name = 'powershell' }
           200 = @{ Parent = 300; Name = 'cmd' }
           300 = @{ Parent = 1;   Name = 'claude' } }

$lookup = { param($id) if ($tree.ContainsKey($id)) { return $tree[$id] } else { return $null } }

Assert-Eq -Actual (Find-ClaudePid -StartPid 100 -Lookup $lookup) -Expected 300 `
          -Name 'walks up to the claude process'

$flat = @{ 100 = @{ Parent = 200; Name = 'powershell' }
           200 = @{ Parent = 1;   Name = 'cmd' } }
$flatLookup = { param($id) if ($flat.ContainsKey($id)) { return $flat[$id] } else { return $null } }

Assert-Eq -Actual (Find-ClaudePid -StartPid 100 -Lookup $flatLookup) -Expected 200 `
          -Name 'falls back to immediate parent when no claude found'

Complete-Tests
