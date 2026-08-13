# stayawake — Design Spec

**Date:** 2026-08-12
**Status:** Approved for planning

## Problem

Closing a laptop lid or letting the machine idle into sleep suspends the Claude Code
process and kills its in-flight API connection. A long autonomous run dies partway
through. This happens on both macOS and Windows, and there is no built-in protection.

`stayawake` is a Claude Code plugin, installable from a GitHub plugin marketplace, that
holds the machine awake for exactly as long as Claude is working — and restores every
setting it changed when the work ends.

## Goals

1. A turn that is running keeps running with the lid closed, on macOS and Windows.
2. Idle sleep is blocked while Claude works; the display still sleeps normally.
3. Every system setting the plugin changes is restored, including after a crash,
   a force-killed terminal, or a power loss.
4. Installable via `/plugin marketplace add` + `/plugin install`. No runtime dependencies.

## Non-goals

- Session resurrection or auto-resume after a session dies anyway. Different problem.
- Keeping the machine awake while Claude is idle at the prompt (except via manual override).
- Linux support in v1.

## Behavior

### When protection is active

Protection engages on `UserPromptSubmit` and releases on `Stop`. Between turns — while
Claude waits for user input — normal power policy applies and the machine may sleep.

`/stayawake on` pins protection for the whole session regardless of turn boundaries.
`/stayawake off` releases it. Session end releases it unconditionally.

### Safety valve

- On AC power: lid-close override is always active while a guard is running.
- On battery: active until charge drops below `batteryFloor` (default 30%). Below the
  floor the guard performs a full restore and releases, letting the machine sleep
  normally rather than running the battery to zero.

### Privileges

`/stayawake setup` is run once and requires one sudo (macOS) or UAC (Windows) approval.
It installs a narrow, named grant that lets the unprivileged guard toggle the lid-close
setting silently thereafter. `/stayawake uninstall` removes the grant completely.

Without `setup`, the plugin still blocks idle sleep (no privileges required) and reports
in `/stayawake status` that lid-close coverage is unavailable.

## Architecture

Three parts:

| Part | Lifetime | Privilege |
|---|---|---|
| Hook shims | milliseconds | none |
| Guard process | one per protected turn | none (delegates lid toggle) |
| Privileged grant | installed once by `setup` | root / admin, narrowly scoped |

Flow of a protected turn:

```
UserPromptSubmit hook  ->  spawn guard (detached, returns immediately)
                               |
                           guard: claim state -> apply -> poll loop
                               |
Stop hook              ->  remove pidfile -> guard observes -> restore -> exit
```

Hooks never block and never modify power settings directly. All mutation lives in the
guard, which is the same process that must stay alive to hold the idle-sleep assertion
on both platforms. Watchdog duty is therefore free rather than an extra component.

### State directory

`~/.stayawake/`

| Path | Purpose |
|---|---|
| `original.json` | Power settings as they were before any guard ran. |
| `guards/<pid>` | One file per live guard. Serves as the refcount. |
| `config.json` | `batteryFloor` (default 30), `enabled` (default true). |

`original.json` is written by the first guard using an atomic create-if-not-exists
(`O_EXCL` / `New-Item` without `-Force`). Concurrent Claude Code sessions therefore
cannot clobber each other's baseline. The last guard to exit — the one that finds
`guards/` empty after removing its own file — performs the restore and deletes
`original.json`.

Each guard reaps pidfiles of dead siblings on every poll, so a killed session's slot is
cleaned by whichever guard still runs, or by the login backstop if none do.

### Guard lifecycle

1. Read current power settings.
2. Atomically create `original.json` if absent; create own `guards/<pid>` file.
3. Apply: idle-sleep block (unprivileged) and lid-close override (via the grant).
4. Poll loop, every 30 seconds:
   - Is the parent PID alive? If not, exit to restore.
   - Does own pidfile still exist? If not (Stop hook removed it), exit to restore.
   - On battery below `batteryFloor`? If so, exit to restore.
   - Reap dead siblings' pidfiles.
5. On exit by any path: remove own pidfile; if last guard, restore from `original.json`
   and delete it.

## Platform implementation

Two modules behind one interface. Bash for macOS, PowerShell 5.1 for Windows. No node,
no python, no packages to install. The hook shim selects by platform.

Each module implements five verbs: `read_state`, `apply`, `restore`, `battery_status`,
`hold_idle`.

### macOS

- **Idle:** `caffeinate -i -s -w <parent_pid>`. `-i` blocks system idle sleep while
  leaving display sleep untouched, so the screen still goes dark. `-w` provides the
  parent-watch natively.
- **Lid:** `sudo pmset -a disablesleep 1`; restored to the value read from `pmset -g`.
- **Grant:** `/etc/sudoers.d/stayawake`, mode 0440, validated with `visudo -c` before
  being moved into place, scoped to exactly `/usr/bin/pmset -a disablesleep *`.
- **Battery:** parsed from `pmset -g batt` (percentage and AC-vs-battery source).
- **Login backstop:** a LaunchAgent with `RunAtLoad` that runs restore-if-stale. It runs
  in the user context and inherits the NOPASSWD rule, so it needs no prompt.

### Windows

- **Idle:** `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)` via `Add-Type`
  P/Invoke. Deliberately omits `ES_DISPLAY_REQUIRED` so the display still sleeps.
- **Lid:** `powercfg /setacvalueindex` and `/setdcvalueindex` on `SUB_BUTTONS` /
  `LIDACTION` set to `0` (do nothing), followed by `/setactive`. Original values read
  from `powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION`.
- **Grant:** two scheduled tasks registered at setup with `RunLevel Highest` —
  `StayAwake\Disable` and `StayAwake\Restore`. The unprivileged guard triggers them with
  `schtasks /run`, which raises no UAC prompt. Two tasks rather than one parameterized
  task because `schtasks /run` cannot reliably pass arguments.
- **Battery:** `Win32_Battery` via WMI for percentage and charging state.
- **Login backstop:** a logon trigger on the Restore task. The script no-ops when no
  state file exists.

### Modern Standby caveat

On Windows laptops using Modern Standby (S0ix), lid-close behavior is partly
firmware-controlled and `LIDACTION` does not always win; some OEM machines drop to
standby regardless. `setup` probes `powercfg /a` and warns when the machine is
S0ix-only, and `/stayawake status` reports this as a known limitation rather than
claiming coverage the plugin cannot deliver.

## Failure handling

- Restore is idempotent: it writes saved values back and is safe to run repeatedly.
- Four independent restore triggers, any one of which is sufficient on its own:
  the `Stop` hook, the guard's own signal trap, the parent-PID poll, the login task.
- If `apply` fails partway — for example the sudoers rule was removed by hand — the
  guard restores whatever it changed, reports the failure into the session, and does not
  proceed in a half-configured state.
- If `original.json` exists but no guards are alive, any guard or the login task treats
  it as stale, restores from it, and deletes it.

## Commands

| Command | Effect |
|---|---|
| `/stayawake setup` | One-time privileged install of the grant and login backstop. |
| `/stayawake uninstall` | Removes grant, login task, and state directory. |
| `/stayawake status` | Reports grant presence, active guards, battery, S0ix warning. |
| `/stayawake on` | Pins protection for the session, independent of turn boundaries. |
| `/stayawake off` | Releases a pinned guard. |

## Testing

- **Unit:** state and refcount logic; parsers for `pmset -g batt` and `powercfg /query`
  against captured fixture text. The parsers are the parts that silently rot when an OS
  changes its output format, so they are tested against fixtures rather than live calls.
- **Integration:** spawn a fake parent process, `kill -9` it, assert settings returned to
  baseline. Same for a battery-floor crossing with a stubbed battery reader. Same for two
  concurrent guards, asserting the baseline is captured once and restored once.
- **Manual matrix** (real sleep cannot be CI-tested), documented in the README: lid close
  on AC; lid close on battery above floor; battery crossing below floor; terminal killed
  mid-turn; hard reboot with a guard running.

## Distribution

A GitHub repository containing `.claude-plugin/plugin.json` and
`.claude-plugin/marketplace.json`, so users run:

```
/plugin marketplace add yelloworangebananaa/stayawake
/plugin install stayawake
```

Licensed MIT. README documents the manual test matrix, the exact contents of the
privileged grant, and how to remove it by hand.
