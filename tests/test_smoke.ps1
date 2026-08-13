. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'assert.ps1')
Assert-Eq -Actual 'a' -Expected 'a' -Name 'harness reports equality'
Complete-Tests
