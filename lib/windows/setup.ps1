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

# Single source of truth for every scheduled task Invoke-SaSetup registers.
# Invoke-SaUninstall iterates $script:SaAllTaskNames (built from the other
# two) rather than its own hardcoded list, so the two can never drift apart
# -- a hardcoded pair in one function and a hardcoded triple in the other is
# exactly how an uninstall silently starts leaving debris behind.
$script:SaElevatedTaskNames = @('Disable', 'Restore') # RunLevel Highest, run lib/windows/lid.ps1
$script:SaBootTaskName      = 'BootRestore'            # unprivileged, AtLogOn -> restore-if-stale boot
$script:SaAllTaskNames      = $script:SaElevatedTaskNames + @($script:SaBootTaskName)

# Pure string-builder for the BootRestore task's Action argument, pulled out
# of Invoke-SaSetup so it's testable without touching Register-ScheduledTask
# or powercfg. Must resolve to BOOT mode specifically, not normal mode:
# normal mode consults guard liveness (Test-PidAlive), and a recycled PID
# making a dead guard look alive is exactly what would block the restore --
# Windows recycles PIDs faster than POSIX, so this is the likelier failure
# here, not a rarer one.
function Get-SaBootRestoreArgument {
  param([string]$StayawakeScript)
  return "-NoProfile -ExecutionPolicy Bypass -File `"$StayawakeScript`" -Verb restore-if-stale -SessionId boot"
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

  $lidScript       = Join-Path $Root 'lib\windows\lid.ps1'
  $stayawakeScript = Join-Path $Root 'bin\stayawake.ps1'

  # Correction 2: New-ScheduledTaskSettingsSet defaults refuse to START a
  # task on battery AND stop a RUNNING task the instant the machine
  # switches to battery. Left at defaults that silently disables lid
  # coverage in exactly the scenario stayawake exists for -- a laptop
  # running on battery with the lid shut. Do not "clean up" these three
  # lines; they are load-bearing, not boilerplate. Every task below shares
  # $settings, including BootRestore: a logon restore that refuses to run
  # because the laptop happens to be on battery is useless exactly when it
  # matters most.
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                                           -DontStopIfGoingOnBatteries `
                                           -ExecutionTimeLimit ([TimeSpan]::Zero)
  $elevatedPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive

  # Neither "Disable" nor "Restore" gets a trigger -- both are purely
  # elevated on-demand helpers, run exclusively via `schtasks /run` (from
  # Invoke-ApplyState and Invoke-RestoreState in lib/windows/platform.ps1,
  # not modified here). Round 2 fix: "Restore" used to also carry an AtLogOn
  # trigger as the original login backstop, designed before BootRestore
  # (below) existed. With both tasks firing at logon and no ordering
  # guarantee between them, an overlap under Task Scheduler's default
  # MultipleInstances=IgnoreNew silently drops whichever one loses the
  # race -- and it's just as likely to drop BootRestore's corrective
  # re-trigger as "Restore"'s own blind read of a stale restore.state,
  # leaving the wrong value applied. BootRestore now owns logon
  # exclusively (clear guards, restore from the real baseline, THEN
  # schtasks-run this task) so there is exactly one entry point and
  # nothing to race. Passing an empty -Trigger array to
  # Register-ScheduledTask is not equivalent to omitting the parameter, so
  # for both tasks the parameter is omitted entirely rather than passed as @().
  foreach ($action in $script:SaElevatedTaskNames) {
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' `
         -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$lidScript`" -Action $action"
    Register-ScheduledTask -TaskName "StayAwake\$action" -Action $a -Principal $elevatedPrincipal `
                           -Settings $settings -Force | Out-Null
  }

  # BootRestore: the actual crash/reboot backstop. A hard reboot or power
  # loss while a guard is registered leaves original.state present and the
  # lid override still applied on disk -- no in-process cleanup ran and no
  # sibling guard is left to reap it. This task is the only thing that runs
  # after that. -RunLevel Limited (unprivileged) on purpose: it only needs
  # to reach Invoke-SaRestoreIfStale -Mode boot, which itself only needs to
  # TRIGGER the elevated Restore work already covered above -- Invoke-RestoreState
  # writes restore.state and runs the "Restore" task; this task must not
  # duplicate that logic, just get boot mode's guard-wipe-then-maybe-restore
  # decision made on every logon. See Get-SaBootRestoreArgument for why the
  # argument string must say "-SessionId boot", not just "restore-if-stale".
  $bootPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Limited -LogonType Interactive
  $bootAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
       -Argument (Get-SaBootRestoreArgument -StayawakeScript $stayawakeScript)
  Register-ScheduledTask -TaskName "StayAwake\$script:SaBootTaskName" -Action $bootAction `
                         -Principal $bootPrincipal -Settings $settings `
                         -Trigger @(New-ScheduledTaskTrigger -AtLogOn) -Force | Out-Null

  Write-Host 'stayawake: setup complete.'
}

function Invoke-SaUninstall {
  # Restore first, with the force mode. Uninstalling while a guard is live
  # must never strand the user's lid setting once the grant is gone.
  Invoke-SaRestoreIfStale -Mode 'force'
  # Iterates $script:SaAllTaskNames (Disable, Restore, BootRestore) -- see
  # that variable's definition above. An uninstall that leaves the logon
  # task behind is worse than not having one.
  foreach ($t in $script:SaAllTaskNames) {
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
