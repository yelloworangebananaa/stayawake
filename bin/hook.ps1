if ($env:OS -ne 'Windows_NT') { exit 0 }
$log = Join-Path $env:TEMP 'stayawake-spike.log'
$stdin = [Console]::In.ReadToEnd()
@(
  "--- hook.ps1 ran at $(Get-Date) ---"
  "pid=$PID ppid=$((Get-CimInstance Win32_Process -Filter ""ProcessId=$PID"").ParentProcessId)"
  "stdin:"
  $stdin
) | Add-Content -Path $log -Encoding utf8
exit 0
