$script:SaTests = 0
$script:SaFails = 0

function Assert-Eq {
  param($Actual, $Expected, [string]$Name)
  $script:SaTests++
  if ("$Actual" -eq "$Expected") {
    Write-Host "  ok   $Name"
  } else {
    Write-Host "  FAIL $Name"
    Write-Host "       expected: [$Expected]"
    Write-Host "       actual:   [$Actual]"
    $script:SaFails++
  }
}

function Complete-Tests {
  Write-Host ""
  Write-Host "$script:SaTests tests, $script:SaFails failures"
  if ($script:SaFails -gt 0) { exit 1 }
  exit 0
}
