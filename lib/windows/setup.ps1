# Windows one-time privileged setup, uninstall, status, and the
# stale-restore backstop. Windows twin of lib/macos/setup.sh -- see that
# file's header and sa_restore_if_stale comment for the full rationale;
# only Windows-specific deltas are called out below. Dot-sourced, not
# executed. Windows PowerShell 5.1 safe.

function Test-Elevated {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SaSetup {
  param([string]$Root)

  if (-not (Test-Elevated)) {
    Write-Host 'stayawake: relaunching with administrator rights to register the power tasks.'
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',
                (Join-Path $Root 'bin\stayawake.ps1'),'-Verb','setup')
    Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait
    return
  }

  # Correction 3: LIDACTION carries a hide attribute and is absent from
  # `powercfg /query SUB_BUTTONS` output until unhidden -- verified
  # empirically on the dev machine, where the query returned only
  # UIBUTTON_ACTION, no LIDACTION entry at all. A machine with no lid omits
  # it even after this. Unhide THEN query -- reversing the order means
  # Get-LidActionLive below sees the same absence it's meant to fix.
  # SUB_BUTTONS / LIDACTION GUIDs match lib/windows/platform.ps1.
  powercfg /attributes 4f971e89-eebd-4455-a8de-9e59040e7347 `
                       5ca83367-6e45-459f-a27b-476b1d01c936 -ATTRIB_HIDE | Out-Null

  $lid = Get-LidActionLive
  if (-not $lid.Present) {
    Write-Host 'stayawake: this machine exposes no lid-close setting (no lid, or firmware-managed).'
    Write-Host '           Idle-sleep blocking will still work. Lid coverage is unavailable.'
  }

  if (Test-ModernStandbyFromText -Text ((powercfg /a 2>&1 | Out-String))) {
    Write-Host 'stayawake: WARNING -- this machine uses Modern Standby (S0 Low Power Idle).'
    Write-Host '           Lid close is partly firmware-controlled and may sleep anyway.'
  }

  $lidScript = Join-Path $Root 'lib\windows\lid.ps1'

  # Correction 2: New-ScheduledTaskSettingsSet defaults refuse to START a
  # task on battery AND stop a RUNNING task the instant the machine
  # switches to battery. Left at defaults that silently disables lid
  # coverage in exactly the scenario stayawake exists for -- a laptop
  # running on battery with the lid shut. Do not "clean up" these three
  # lines; they are load-bearing, not boilerplate.
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                                           -DontStopIfGoingOnBatteries `
                                           -ExecutionTimeLimit ([TimeSpan]::Zero)
  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive

  # Only "Restore" gets a trigger (AtLogOn -- the crash/reboot backstop:
  # lid.ps1's own Restore branch already defaults safely to Sleep(1,1) when
  # restore.state is absent or unparseable, see that file's header comment).
  # "Disable" is on-demand only, run exclusively via `schtasks /run` from
  # Invoke-ApplyState in lib/windows/platform.ps1 -- passing an empty
  # -Trigger array to Register-ScheduledTask for it is not equivalent to
  # omitting the parameter, so the parameter is omitted entirely rather than
  # passed as @().
  foreach ($action in @('Disable','Restore')) {
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' `
         -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$lidScript`" -Action $action"
    $registerArgs = @{
      TaskName  = "StayAwake\$action"
      Action    = $a
      Principal = $principal
      Settings  = $settings
      Force     = $true
    }
    if ($action -eq 'Restore') {
      $registerArgs['Trigger'] = @(New-ScheduledTaskTrigger -AtLogOn)
    }
    Register-ScheduledTask @registerArgs | Out-Null
  }

  Write-Host 'stayawake: setup complete.'
}

function Invoke-SaUninstall {
  # Restore first, with the force mode. Uninstalling while a guard is live
  # must never strand the user's lid setting once the grant is gone.
  Invoke-SaRestoreIfStale -Mode 'force'
  foreach ($t in @('Disable','Restore')) {
    Unregister-ScheduledTask -TaskName "StayAwake\$t" -Confirm:$false -ErrorAction SilentlyContinue
  }
  $d = Get-StateDir
  if (Test-Path $d) { Remove-Item $d -Recurse -Force }
  Write-Host 'stayawake: uninstalled. Scheduled tasks and state removed.'
}

# Restores stale power settings a guard left behind. Three modes, selected
# by -Mode. Windows twin of sa_restore_if_stale in lib/macos/setup.sh --
# see that function's header comment for the full rationale behind each
# mode; only Windows-specific deltas are called out below.
#
#   ''      Normal/manual (CLI, ad-hoc troubleshooting). Reaps dead guards,
#           then restores only if no live guard remains -- a genuinely
#           running guard still owns the baseline and restores it itself
#           on its own exit path.
#
#   'force' Used by Invoke-SaUninstall. Same reaping, but restores
#           regardless of guard count: uninstalling must never leave the
#           lid setting permanently overridden just because some guard
#           file is still sitting there.
#
#   'boot'  Reboot/crash-recovery mode. No guard process survives a
#           reboot, so every guard file left over from before the reboot
#           is stale by definition -- whatever its PID claims. Windows
#           recycles PIDs considerably faster than POSIX, so a leftover
#           guard file's PID can already belong to an unrelated,
#           long-lived process by the time this runs, which would make
#           Test-PidAlive report it "live" and wedge the very backstop
#           this mode exists to run. Correction 1: this mode therefore
#           never calls Remove-DeadGuards or Get-GuardCount (both consult
#           Test-PidAlive) -- it wipes the guards directory unconditionally
#           via Remove-Item, then restores from the baseline if one
#           exists. A boot path that delegates to a liveness-checking
#           helper looks correct and preserves the bug; do not "simplify"
#           this branch into a call to Remove-DeadGuards.
function Invoke-SaRestoreIfStale {
  param([string]$Mode = '')

  switch ($Mode) {
    'boot' {
      $d = Get-GuardsDir
      if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    }
    'force' {
      Remove-DeadGuards
    }
    default {
      Remove-DeadGuards
      if ((Get-GuardCount) -gt 0) { return }
    }
  }

  $b = Read-Baseline
  if (-not $b) { return }
  Invoke-RestoreState -Baseline $b
  Clear-Baseline
  Write-Host 'stayawake: restored stale power settings.'
}

function Invoke-SaStatus {
  $task = Get-ScheduledTask -TaskName 'Disable' -TaskPath '\StayAwake\' -ErrorAction SilentlyContinue
  if ($task) {
    Write-Host 'grant:      installed (StayAwake scheduled tasks)'
  } else {
    Write-Host 'grant:      NOT installed - run "stayawake setup" for lid-close coverage'
  }
  $lid = Get-LidActionLive
  if (-not $lid.Present) { Write-Host 'lid:        unavailable on this machine' }
  if (Test-ModernStandbyFromText -Text ((powercfg /a 2>&1 | Out-String))) {
    Write-Host 'lid:        Modern Standby machine - lid coverage unreliable'
  }
  Write-Host "guards:     $(Get-GuardCount) active"
  $p = Get-PowerSource
  Write-Host "power:      $($p.Source) $($p.Percent)"
  $b = Read-Baseline
  if (-not $b) { $b = 'none' }
  Write-Host "baseline:   $b"
}
