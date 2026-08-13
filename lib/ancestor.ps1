# Walks the process tree to find the Claude Code process the guard should watch.
# Lookup is injectable so the walker is testable without a real process tree.

function Get-ProcessNode {
  param([int]$ProcessId)
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
  if ($null -eq $p) { return $null }
  return @{ Parent = [int]$p.ParentProcessId; Name = [string]$p.Name }
}

function Find-ClaudePid {
  param([int]$StartPid, [scriptblock]$Lookup = ${function:Get-ProcessNode})
  $node = & $Lookup $StartPid
  if ($null -eq $node) { return $StartPid }
  $fallback = $node.Parent
  $cur = $StartPid
  for ($i = 0; $i -lt 6; $i++) {
    $n = & $Lookup $cur
    if ($null -eq $n) { break }
    $cur = $n.Parent
    if ($cur -le 1) { break }
    $parentNode = & $Lookup $cur
    if ($null -eq $parentNode) { break }
    # -like is case-insensitive; shell version uses case-sensitive glob.
    # Intentional: Windows process names are not case-consistent.
    if ($parentNode.Name -like '*claude*') { return $cur }
  }
  return $fallback
}
