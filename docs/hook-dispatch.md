# Hook dispatch spike: findings

Empirical answer to "what does `command` in `hooks.json` need to look like to run on both platforms."

## Method

Installed the plugin for real, via the actual marketplace/install path — not the settings.json
fallback:

```bash
cd "C:\Users\ryzen 9\Desktop\letting claude work"
claude plugin marketplace add ./      # `add .` is rejected; `./` is required
claude plugin install stayawake
```

`claude plugin marketplace add .` (the literal form in the original brief) fails with
`Invalid marketplace source format. Try: owner/repo, https://..., or ./path` — the leading `./`
is mandatory. `claude plugin marketplace add ./` succeeds.

Fired the hooks headlessly from a scratch directory (`claude -p` triggers `UserPromptSubmit`
without needing an interactive TUI session), then read `$TEMP/stayawake-spike.log`:

```bash
cd /path/to/scratch
claude -p "say hi"
```

Two runs: one with `bin/hook.sh` / `bin/hook.ps1` as plain loggers (no OS guard), one after adding
the Step 7 guards, to confirm the guard actually suppresses the wrong-platform script.

Since this used the real plugin install, `${CLAUDE_PLUGIN_ROOT}` expansion **was verified**
(not the settings.json fallback — note 3's caveat does not apply here).

## Findings

**Both command forms executed on Windows.** This dev machine has Git Bash installed alongside
native Windows, so `sh` resolves on `PATH` and runs `bin/hook.sh` via Git Bash's `sh`, while
`powershell -NoProfile -ExecutionPolicy Bypass -File ...` runs `bin/hook.ps1` via Windows
PowerShell 5.1 — both succeeded, both wrote to the log, both exited 0. Neither command failed to
launch. This is the "if BOTH fire on one platform, note it" case from ambiguity note 5.

- `${CLAUDE_PLUGIN_ROOT}` expanded correctly. Observed `hook.sh`'s `$0` as
  `C:/Users/ryzen 9/Desktop/letting claude work//bin/hook.sh` (double slash is harmless — the
  root already had a trailing element and `/bin/hook.sh` was appended per the `hooks.json`
  template; `sh` resolves it fine).
- No exit-code-based "form that could not run" was observed — on this machine, both forms are
  runnable, so there is nothing to report there. **Caveat:** this machine has Git Bash on `PATH`
  providing `sh`. A Windows machine without Git Bash (or any POSIX `sh`) was not tested; on such a
  machine the `sh` command form would be expected to fail to spawn (ENOENT-style failure), which
  Claude Code logs but does not surface as blocking. This inference is untested, not observed.
- `TMPDIR` is unset in this Git Bash environment, so `bin/hook.sh`'s `"${TMPDIR:-/tmp}"` fallback
  resolved to `/tmp`, which Git Bash maps to the same underlying directory as Windows `%TEMP%`
  (confirmed via `cd /tmp && pwd` → `/tmp`, and `cd "$TEMP" && pwd` → `/tmp`). Both logging
  destinations in Step 6 are therefore the same file on this machine, not independent locations.

### Hook stdin payload (`UserPromptSubmit`)

Exact JSON observed on stdin, for both the `sh` and the `powershell` command forms (byte-identical
content delivered to each):

```json
{"session_id":"d1b2478b-7447-4a59-8f93-dc24bd11be88","transcript_path":"C:\\Users\\ryzen 9\\.claude\\projects\\C--Users-ryzen-9-Desktop-stayawake-scratch\\d1b2478b-7447-4a59-8f93-dc24bd11be88.jsonl","cwd":"C:\\Users\\ryzen 9\\Desktop\\stayawake-scratch","prompt_id":"cda03721-d836-4b19-bc36-4cc680353dcc","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"say hi"}
```

Fields: `session_id`, `transcript_path`, `cwd`, `prompt_id`, `permission_mode`, `hook_event_name`,
`prompt`.

**`session_id` IS present.** Task 12's plan to key guard files on `session_id` is sound as far as
this payload shape goes.

### Guard verification

After adding the Step 7 guards (`[ "$(uname -s)" = "Darwin" ] || exit 0` in `bin/hook.sh`;
`if ($env:OS -ne 'Windows_NT') { exit 0 }` in `bin/hook.ps1`), re-ran the same headless prompt on
this Windows machine:

- `bin/hook.sh` produced **no log entry** (guard exited 0 before logging) — confirmed correct.
- `bin/hook.ps1` still logged normally — confirmed correct.

The plugin picked up the edited scripts live from the source directory with no reinstall needed
(local marketplace installs reference the source path, they don't copy it).

## Recommendation for the final `hooks.json` dispatch form

Keep both command forms registered unconditionally, exactly as in Step 5 — do not try to select
one form based on platform detection in `hooks.json` itself (there is no portable way to do OS
branching in the JSON, and Claude Code has no built-in platform-conditional hook syntax as of
2.1.229). Instead:

```json
{ "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/bin/hook.sh\"" },
{ "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"${CLAUDE_PLUGIN_ROOT}/bin/hook.ps1\"" }
```

Push all platform discrimination into the scripts themselves via the Step 7 guards. This is
already what's implemented in this repo. Task 12 must keep both guards in place on every script
pair added later (not just `hook.sh`/`hook.ps1`) — any Windows machine with Git Bash on `PATH`
will run both command forms, so both scripts must self-exclude on the wrong OS or the awake-guard
logic will double-apply.
