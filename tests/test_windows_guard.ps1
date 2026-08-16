$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'assert.ps1')

$tempDir = (Get-Item $env:TEMP).FullName
$env:STAYAWAKE_HOME = Join-Path $tempDir "stayawake-guardtest-$PID"
if (Test-Path $env:STAYAWAKE_HOME) { Remove-Item $env:STAYAWAKE_HOME -Recurse -Force }
New-Item -ItemType Directory -Force -Path $env:STAYAWAKE_HOME | Out-Null

$stub = Join-Path $env:STAYAWAKE_HOME 'stub_platform.ps1'
$env:STAYAWAKE_STUB_LOG = Join-Path $env:STAYAWAKE_HOME 'calls.log'
@'
function Get-CurrentState { return "lidAc=1;lidDc=1" }
function Invoke-ApplyState { Add-Content -Path $env:STAYAWAKE_STUB_LOG -Value "apply" }
function Invoke-RestoreState { param([string]$Baseline) Add-Content -Path $env:STAYAWAKE_STUB_LOG -Value "restore:$Baseline" }
function Get-PowerSource {
  $p = $env:STAYAWAKE_STUB_POWER
  if (-not $p) { $p = "ac 100" }
  $parts = $p.Split(" ")
  return [pscustomobject]@{ Source = $parts[0]; Percent = [int]$parts[1] }
}
function Set-IdleAssertion { param([bool]$On) }
'@ | Set-Content -Path $stub -Encoding utf8

$env:STAYAWAKE_PLATFORM_STUB = $stub
$env:STAYAWAKE_POLL = '1'
$guard = Join-Path $here '..\bin\guard.ps1'
# Start-Process -ArgumentList (array form) does not reliably quote elements
# that contain spaces -- this repo's own path does (".../ryzen 9/..."), and
# an unquoted $guard here gets split at the space, producing
# "Processing -File 'C:\Users\ryzen' failed because the file does not have
# a '.ps1' extension." with the child exiting immediately and never writing
# anything. Pre-quoting the path into its own token sidesteps that.
$guardQ = '"' + $guard + '"'

# --- low battery: no apply, no registration ---
# Positive control: assert the child actually launched and ran its
# early-exit path (exit 0) rather than merely asserting the absence of
# apply/registration side effects -- a child that fails to launch at all
# (e.g. the same path-quoting trap $guardQ exists for, below) would satisfy
# those absence checks just as well as a correctly-declining guard, and the
# test would pass for the wrong reason.
$env:STAYAWAKE_STUB_POWER = 'battery 12'
& powershell -NoProfile -ExecutionPolicy Bypass -File $guard -SessionId 'sess-low' -Kind 'turn' -ParentPid $PID
Assert-Eq -Actual $LASTEXITCODE -Expected 0 -Name 'low battery guard process actually ran and exited cleanly'
$log = ''
if (Test-Path $env:STAYAWAKE_STUB_LOG) { $log = (Get-Content $env:STAYAWAKE_STUB_LOG -Raw) }
Assert-Eq -Actual $log -Expected '' -Name 'low battery guard never applies'
Assert-Eq -Actual (@(Get-ChildItem (Join-Path $env:STAYAWAKE_HOME 'guards') -File -ErrorAction SilentlyContinue).Count) `
          -Expected 0 -Name 'low battery guard registers nothing'

# --- AC: applies, then restores when its guard file is deleted ---
$env:STAYAWAKE_STUB_POWER = 'ac 100'
$p = Start-Process powershell -PassThru -WindowStyle Hidden `
     -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$guardQ,
                   '-SessionId','sess-ac','-Kind','turn','-ParentPid',$PID
# A fresh powershell.exe spin-up (interpreter start + dot-sourcing lib/state.ps1
# and the stub) is not instant; poll for the apply line instead of a fixed
# sleep, bounded so a genuine failure still fails the assertion rather than
# hanging. Note \r?$ below, not a bare $: Add-Content writes CRLF line
# endings on Windows, and .NET's $ in multiline mode anchors immediately
# before \n only -- it does NOT skip a preceding \r -- so a bare '^apply$'
# never matches "apply\r\n" and silently reports 0 forever. This bit the
# brief's own reference template; \r? makes the anchor CRLF-safe.
$deadline = (Get-Date).AddSeconds(15)
$log = ''
while ((Get-Date) -lt $deadline) {
  if (Test-Path $env:STAYAWAKE_STUB_LOG) {
    $log = Get-Content $env:STAYAWAKE_STUB_LOG -Raw
    if ($log -match '(?m)^apply\r?$') { break }
  }
  Start-Sleep -Milliseconds 500
}
Assert-Eq -Actual (@([regex]::Matches($log,'^apply\r?$','Multiline')).Count) -Expected 1 -Name 'AC guard applied once'
Remove-Item (Join-Path $env:STAYAWAKE_HOME 'guards\sess-ac-turn') -Force
Start-Sleep -Seconds 4
$log = Get-Content $env:STAYAWAKE_STUB_LOG -Raw
Assert-Eq -Actual (@([regex]::Matches($log,'restore:lidAc=1;lidDc=1')).Count) -Expected 1 `
          -Name 'guard restored after its file was removed'
Assert-Eq -Actual (Test-Path (Join-Path $env:STAYAWAKE_HOME 'original.state')) -Expected $false `
          -Name 'baseline cleared by last guard out'

# --- force-kill: parent dies via Stop-Process -Force, guard still restores ---
# This is the crash-safety guarantee of the whole project: try/finally does
# NOT run in the killed process, so restore must come from a layer that
# survives the kill (here: the next poll tick sees the parent is gone and
# breaks, running its OWN try/finally -- the guard being tested is never
# itself force-killed; its *parent* is). Assert the log is empty
# immediately before the kill so an earlier unrelated restore above cannot
# satisfy this assertion.
Clear-Content $env:STAYAWAKE_STUB_LOG
$logBeforeKill = Get-Content $env:STAYAWAKE_STUB_LOG -Raw -ErrorAction SilentlyContinue
Assert-Eq -Actual ([string]::IsNullOrEmpty($logBeforeKill)) -Expected $true -Name 'log is empty immediately before the kill'

$fake = Start-Process powershell -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 60'
Start-Process powershell -WindowStyle Hidden `
  -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$guardQ,
                '-SessionId','sess-kill','-Kind','turn','-ParentPid',$fake.Id | Out-Null
Start-Sleep -Seconds 3
Stop-Process -Id $fake.Id -Force
Start-Sleep -Seconds 4
$log = Get-Content $env:STAYAWAKE_STUB_LOG -Raw
Assert-Eq -Actual (@([regex]::Matches($log,'restore:')).Count) -Expected 1 `
          -Name 'guard restored after parent was force-killed'

Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
