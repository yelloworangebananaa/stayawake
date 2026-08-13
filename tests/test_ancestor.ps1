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

# Test deep chain - claude at level 6 (should be found, verifies 6-level cap)
$deep6 = @{
  1000 = @{ Parent = 1001; Name = 'powershell' }
  1001 = @{ Parent = 1002; Name = 'bash' }
  1002 = @{ Parent = 1003; Name = 'python' }
  1003 = @{ Parent = 1004; Name = 'docker' }
  1004 = @{ Parent = 1005; Name = 'systemd' }
  1005 = @{ Parent = 1006; Name = 'node' }
  1006 = @{ Parent = 1;    Name = 'claude' }
}
$deep6Lookup = { param($id) if ($deep6.ContainsKey($id)) { return $deep6[$id] } else { return $null } }

Assert-Eq -Actual (Find-ClaudePid -StartPid 1000 -Lookup $deep6Lookup) -Expected 1006 `
          -Name 'finds claude at level 6'

# Test deep chain - claude at level 7 (past cap, should return fallback and verify cap)
$deep7 = @{
  2000 = @{ Parent = 2001; Name = 'powershell' }
  2001 = @{ Parent = 2002; Name = 'bash' }
  2002 = @{ Parent = 2003; Name = 'python' }
  2003 = @{ Parent = 2004; Name = 'docker' }
  2004 = @{ Parent = 2005; Name = 'systemd' }
  2005 = @{ Parent = 2006; Name = 'node' }
  2006 = @{ Parent = 2007; Name = 'npm' }
  2007 = @{ Parent = 1;    Name = 'claude' }
}
$deep7Lookup = { param($id) if ($deep7.ContainsKey($id)) { return $deep7[$id] } else { return $null } }

Assert-Eq -Actual (Find-ClaudePid -StartPid 2000 -Lookup $deep7Lookup) -Expected 2001 `
          -Name 'falls back when claude is at level 7 (past 6-level cap)'

# Test PID 1 boundary - resolvable but walker should stop there
$pid1boundary = @{
  3000 = @{ Parent = 3001; Name = 'powershell' }
  3001 = @{ Parent = 1;    Name = 'bash' }
  1    = @{ Parent = 0;    Name = 'init' }
}
$pid1Lookup = { param($id) if ($pid1boundary.ContainsKey($id)) { return $pid1boundary[$id] } else { return $null } }

Assert-Eq -Actual (Find-ClaudePid -StartPid 3000 -Lookup $pid1Lookup) -Expected 3001 `
          -Name 'stops at PID 1 boundary even when resolvable'

Complete-Tests
