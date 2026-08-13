$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$rc = 0
Get-ChildItem -Path $here -Filter 'test_*.ps1' | ForEach-Object {
  Write-Host ""
  Write-Host "== $($_.Name) =="
  & powershell -NoProfile -ExecutionPolicy Bypass -File $_.FullName
  if ($LASTEXITCODE -ne 0) { $rc = 1 }
}
exit $rc
