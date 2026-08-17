# stayawake

Keeps your machine awake while Claude Code is working, and releases it the
moment the turn ends — on macOS and Windows.

**Published:** [github.com/yelloworangebananaa/stayawake](https://github.com/yelloworangebananaa/stayawake)
· v0.9.0 · MIT

This repository is itself a Claude Code plugin marketplace — installing it
needs nothing but the two commands under [Install](#install).

## ⚠️ Status: unverified on real hardware

This plugin was built and tested on a Windows desktop with **no lid** and
**no permission to make admin/root changes to the machine**. As a result:

- The entire **macOS privileged path** — `pmset`, `visudo`, `sudo install`,
  the LaunchAgent — is written and code-reviewed, but **no Mac has ever run
  it.**
- The **Windows privileged path** — `powercfg` writes, `powercfg /attributes`
  unhiding `LIDACTION`, `Register-ScheduledTask` — is written and
  code-reviewed, but **no scheduled task has ever actually been registered.**
- **Lid-close behavior itself has never been observed, on either platform.**

The unit and integration test suites pass (they exercise the logic against
fakes and mocks), and the code has been read carefully. But nothing above
has been run for real. If you install this, you are the first real test of
the privileged paths. See the [manual test matrix](#manual-test-matrix)
below — every row in it is currently unrun.

## What it does

While Claude Code is working, stayawake blocks the machine from going to
*system* idle sleep (and, once you grant it access, from sleeping when the
lid is closed). It releases that block the instant the turn ends, restoring
whatever power setting was in effect before. It does **not** stop the
display from sleeping — that's deliberate: only system idle sleep is
blocked, so your screen still blanks normally while a long turn runs in the
background.

## Install

```
/plugin marketplace add yelloworangebananaa/stayawake
/plugin install stayawake@stayawake
/stayawake setup
```

The `plugin@marketplace` form is required here because the plugin and the
marketplace share the name `stayawake`.

Already installed? Pick up a new version with:

```
/plugin marketplace update stayawake
/plugin install stayawake@stayawake
```

`setup` is optional — see [What `setup` grants](#what-setup-grants) below
for what you get without it.

## What `setup` grants

`setup` asks for one administrator/sudo approval to install a narrow,
permanent grant so stayawake can also cover lid-close (not just idle
sleep). Without running `setup`, idle-sleep blocking still works out of the
box; only lid-close coverage is unavailable.

### macOS

A sudoers rule at `/etc/sudoers.d/stayawake`, permitting exactly two
commands and nothing else (from `lib/macos/setup.sh`):

```
%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

This lets any admin user toggle `pmset disablesleep` without a password
prompt — and only that. It cannot be used to run arbitrary commands as
root.

`setup` also installs a LaunchAgent
(`~/Library/LaunchAgents/com.stayawake.restore.plist`) that runs at login
and restores any power setting a guard left applied if the machine was
rebooted or crashed while a turn was in progress.

### Windows

Three scheduled tasks under `\StayAwake\` (from `lib/windows/setup.ps1`):

| Task | Runs as | Trigger | Does |
|---|---|---|---|
| `StayAwake\Disable` | elevated (Highest) | none — invoked on demand via `schtasks /run` | Runs `lib/windows/lid.ps1 -Action Disable`, turning off the lid-close power action while a guard is active |
| `StayAwake\Restore` | elevated (Highest) | none — invoked on demand via `schtasks /run` | Runs `lib/windows/lid.ps1 -Action Restore`, putting the lid-close power action back to what it was |
| `StayAwake\BootRestore` | limited (unprivileged) | `AtLogOn` | Runs `stayawake.ps1 -Verb restore-if-stale -SessionId boot`, which wipes any leftover guard state and restores the pre-turn power setting if a crash or hard reboot happened mid-turn |

`Disable` and `Restore` are deliberately given no trigger — they only ever
run on demand from stayawake's own code, never automatically. `BootRestore`
is the only task that runs unattended, and it's unprivileged.

## How to remove it by hand

If `/stayawake uninstall` isn't available or you'd rather do it yourself:

**macOS**
```
sudo rm /etc/sudoers.d/stayawake
launchctl unload ~/Library/LaunchAgents/com.stayawake.restore.plist
rm ~/Library/LaunchAgents/com.stayawake.restore.plist
rm -rf ~/.stayawake
```

**Windows**
```
Unregister-ScheduledTask -TaskPath '\StayAwake\' -TaskName 'Disable' -Confirm:$false
Unregister-ScheduledTask -TaskPath '\StayAwake\' -TaskName 'Restore' -Confirm:$false
Unregister-ScheduledTask -TaskPath '\StayAwake\' -TaskName 'BootRestore' -Confirm:$false
Remove-Item "$env:USERPROFILE\.stayawake" -Recurse -Force
```

This restores any power setting stayawake currently has applied before
removing its state, the same way `/stayawake uninstall` does.

## Limits

- **Battery floor.** Default 30% (`batteryFloor` in config). Below the
  floor, the guard releases and lets the machine sleep normally rather than
  running the battery to zero.
- **Windows Modern Standby.** On machines using Modern Standby (S0 Low
  Power Idle), lid-close behavior is partly firmware-controlled. `setup`
  and `status` warn when this is detected, but the firmware may still put
  the machine to sleep on lid close regardless of the power setting
  stayawake applies.
- **macOS process-name matching (unverified).** The guard identifies the
  Claude Code process to watch by walking the process tree and matching
  `ps -o comm=` output containing `claude` (`lib/ancestor.sh`). If Claude
  Code is installed as a Node-hosted script rather than a native binary,
  `comm` may report `node` instead, the match fails, and the guard silently
  falls back to watching its immediate parent process instead — one of the
  four restore triggers degrades quietly. This has not been checked against
  a real macOS install of Claude Code.

## Config

`~/.stayawake/config.json`:

```json
{ "batteryFloor": 30 }
```

## Manual test matrix

**None of these have been run yet.** Everything below is a plan to run
before trusting the privileged paths, not a record of results. Update this
table with pass/fail and the machine used as scenarios are actually run.

| # | Scenario | Steps | Expected | Status |
|---|---|---|---|---|
| 1 | Lid close on AC | Plug in, start a 10-minute turn, close the lid for 5 min, open | Turn still running, output continued while closed | Not run |
| 2 | Idle on AC | Plug in, start a long turn, do not touch the machine past the idle timeout | Display sleeps, turn keeps running | Not run |
| 3 | Lid close on battery above floor | Unplug at >50%, start a long turn, close lid 5 min | Turn still running | Not run |
| 4 | Battery crosses the floor | Set `batteryFloor` to just under current charge, run until it crosses | Guard releases, `status` shows 0 guards, settings restored | Not run |
| 5 | Terminal killed mid-turn | Start a turn, `kill -9` the Claude process | Within 30s, `status` shows 0 guards and the original setting restored | Not run |
| 6 | Hard reboot with a guard live | Start a turn, hold the power button, boot, log in | Login task restores; `status` shows `baseline: none` | Not run |
| 7 | Two concurrent sessions | Start turns in two terminals, end one | Setting stays applied until the second ends, then restores once | Not run |
| 8 | Uninstall while a guard is live | Start a turn, run `/stayawake uninstall` | Setting restored, grant and state gone | Not run |
| 9 | macOS process-name check | On a Mac, start a turn, inspect what `find_claude_pid` (`lib/ancestor.sh`) actually resolves to | `find_claude_pid` returns the real `claude` PID, not a fallback to the immediate parent | Not run |
| 10 | Windows trigger-removal on upgrade | Manually register `StayAwake\Restore` with an `AtLogOn` trigger, then run `setup` again | `(Get-ScheduledTask -TaskName Restore -TaskPath '\StayAwake\').Triggers` is empty afterward — confirms `Register-ScheduledTask -Force` replaces rather than merges triggers | Not run |
| 11 | Windows idle assertion holds | Start a long turn, wait past the system idle timeout | Machine does not sleep; display still sleeps normally | Not run |

Scenarios 1–6 and 9–11 should be run on both macOS and Windows before this
plugin is trusted for unattended use. Scenarios 5 and 6 are the
crash-safety guarantee — no unit test covers the real reboot or kill path.

## License

MIT. Author: yelloworangebananaa.
