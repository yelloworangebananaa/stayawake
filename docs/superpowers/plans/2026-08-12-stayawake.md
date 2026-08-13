# stayawake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Claude Code plugin that keeps macOS and Windows machines awake — through idle timeouts and lid close — for exactly as long as Claude is working on a turn, and restores every changed setting afterwards even after a crash.

**Architecture:** Hooks spawn a detached per-turn *guard* process. The guard is the same process that must stay alive to hold the OS idle-sleep assertion, so watchdog duty is free. It saves the system's original power settings to a shared state directory under a refcount, applies its changes, polls parent liveness and battery, and restores on every exit path. A one-time privileged setup installs a narrow grant (sudoers rule / elevated scheduled tasks) so the unprivileged guard can toggle lid-close silently.

**Tech Stack:** POSIX sh + `caffeinate` + `pmset` on macOS. Windows PowerShell 5.1 + `SetThreadExecutionState` P/Invoke + `powercfg` + Task Scheduler on Windows. No node, no python, no packages.

## Global Constraints

Every task's requirements implicitly include this section.

- **Zero runtime dependencies.** No node, no python, no npm/pip/brew packages. Only tools shipped with the OS.
- **macOS scripts must run under bash 3.2**, the system bash. No associative arrays, no `${var,,}`, no `mapfile`, no `[[ ... ]] =~` niceties beyond bash 3.2.
- **Windows scripts must run under Windows PowerShell 5.1.** No ternary `? :`, no `??`, no `&&`/`||` chaining, no `-AsHashtable`.
- **Every exit path restores.** No code path may leave a modified power setting behind. This is the one rule that overrides brevity.
- **`STAYAWAKE_HOME` env var overrides the state directory.** Every state function must honour it, or the tests cannot run without touching the real `~/.stayawake`.
- **All `.sh` files are LF-only** via `.gitattributes`. A CRLF shebang is a hard failure on macOS, and this repo is developed on Windows.
- **License MIT.** Author `yelloworangebananaa`. Commits are authored as the user with no co-author trailer.
- **State file is `original.state`**, plain `key=value` lines — not JSON. POSIX sh has no JSON parser and dependencies are banned.

### Deviations from the spec, already agreed

| Spec said | Plan does | Why |
|---|---|---|
| `original.json` | `original.state`, `key=value` | No JSON parser available in sh without dependencies. |
| sudoers scoped `pmset -a disablesleep *` | Two exact commands, no wildcard | Tighter grant, identical function. |
| — | Windows setup unhides `LIDACTION` first | Verified on the dev machine: `powercfg /query SUB_BUTTONS` omits `LIDACTION`. Without unhiding, the Windows path silently no-ops. |

---

## File Structure

```
stayawake/
├── .claude-plugin/
│   ├── plugin.json              # plugin manifest
│   └── marketplace.json         # marketplace manifest (this repo is its own marketplace)
├── .gitattributes               # LF enforcement for .sh
├── hooks/
│   └── hooks.json               # UserPromptSubmit / Stop / SessionEnd wiring
├── commands/
│   └── stayawake.md             # /stayawake slash command
├── bin/
│   ├── hook.sh                  # macOS hook entry: parse stdin, dispatch
│   ├── hook.ps1                 # Windows hook entry
│   ├── guard.sh                 # macOS guard loop
│   ├── guard.ps1                # Windows guard loop
│   ├── stayawake.sh             # macOS CLI verbs (setup/uninstall/status/on/off/restore-if-stale)
│   └── stayawake.ps1            # Windows CLI verbs
├── lib/
│   ├── state.sh                 # state dir, baseline claim, guard refcount  (macOS)
│   ├── state.ps1                # same, Windows
│   ├── ancestor.sh              # find the claude process PID to watch
│   ├── ancestor.ps1
│   ├── macos/
│   │   ├── platform.sh          # parsers + apply/restore + battery
│   │   └── setup.sh             # sudoers + LaunchAgent install/uninstall
│   └── windows/
│       ├── platform.ps1         # parsers + battery
│       ├── lid.ps1              # the elevated script the scheduled tasks run
│       └── setup.ps1            # scheduled task install/uninstall + S0ix probe
├── tests/
│   ├── assert.sh / assert.ps1   # ~30-line assertion harness
│   ├── run.sh   / run.ps1       # test runners
│   ├── test_*.sh / test_*.ps1
│   └── fixtures/                # captured real command output
├── .github/workflows/test.yml
├── README.md
└── LICENSE
```

**Why state logic is duplicated in sh and ps1:** the Windows guard must be a PowerShell process to hold `SetThreadExecutionState` in-process, and the macOS guard must be a shell to wrap `caffeinate`. The split is forced at the guard level regardless, so a shared implementation would require a third runtime — which the zero-dependency rule forbids. Roughly 80 lines are duplicated. This is deliberate.

---

### Task 1: Repo skeleton, manifests, and the hook-dispatch spike

The one genuine unknown in this plan: which shell Claude Code uses to run plugin hook commands on Windows. Everything else depends on the answer, so it is resolved first, empirically, on the dev machine.

**Files:**
- Create: `.gitattributes`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `LICENSE`, `hooks/hooks.json`, `bin/hook.sh`, `bin/hook.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: a locally installable plugin, and a documented answer to "what does `command` in `hooks.json` need to look like to run on both platforms".

- [ ] **Step 1: Create `.gitattributes`**

```gitattributes
* text=auto eol=lf
*.ps1 text eol=crlf
*.cmd text eol=crlf
*.sh  text eol=lf
bin/hook.sh   text eol=lf
bin/guard.sh  text eol=lf
```

- [ ] **Step 2: Create `.claude-plugin/plugin.json`**

```json
{
  "name": "stayawake",
  "description": "Keeps macOS and Windows awake through idle and lid close while Claude is working, and restores every setting afterwards",
  "version": "0.1.0",
  "author": { "name": "yelloworangebananaa" },
  "homepage": "https://github.com/yelloworangebananaa/stayawake",
  "repository": "https://github.com/yelloworangebananaa/stayawake",
  "license": "MIT",
  "keywords": ["sleep", "power", "lid", "macos", "windows", "long-running"]
}
```

- [ ] **Step 3: Create `.claude-plugin/marketplace.json`**

```json
{
  "name": "stayawake",
  "owner": { "name": "yelloworangebananaa" },
  "plugins": [
    {
      "name": "stayawake",
      "source": "./",
      "description": "Keeps your machine awake while Claude Code is working — lid closed or idle."
    }
  ]
}
```

- [ ] **Step 4: Write the spike hooks — they only log**

`bin/hook.sh`:

```sh
#!/bin/sh
# Spike: record that we ran, what shell we are, and what stdin looked like.
{
  echo "--- hook.sh ran at $(date) ---"
  echo "shell=$0 ppid=$PPID"
  echo "stdin:"
  cat
} >> "${TMPDIR:-/tmp}/stayawake-spike.log" 2>&1
exit 0
```

`bin/hook.ps1`:

```powershell
$log = Join-Path $env:TEMP 'stayawake-spike.log'
$stdin = [Console]::In.ReadToEnd()
@(
  "--- hook.ps1 ran at $(Get-Date) ---"
  "pid=$PID ppid=$((Get-CimInstance Win32_Process -Filter ""ProcessId=$PID"").ParentProcessId)"
  "stdin:"
  $stdin
) | Add-Content -Path $log -Encoding utf8
exit 0
```

- [ ] **Step 5: Wire both into `hooks/hooks.json`, betting on neither**

Register both commands for `UserPromptSubmit`. Whichever the platform can execute, runs; the other fails harmlessly with a non-zero exit, which Claude Code logs but does not surface as a blocking error.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/bin/hook.sh\"" },
          { "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"${CLAUDE_PLUGIN_ROOT}/bin/hook.ps1\"" }
        ]
      }
    ]
  }
}
```

- [ ] **Step 6: Install locally and fire it**

```bash
# from the repo root
claude plugin marketplace add .
claude plugin install stayawake
```

Then start a Claude Code session in a scratch directory, submit any prompt, and read both logs:

```bash
cat "$TEMP/stayawake-spike.log" 2>/dev/null; cat /tmp/stayawake-spike.log 2>/dev/null
```

Expected: at least one log exists. Record in `docs/hook-dispatch.md`: which command ran, whether `${CLAUDE_PLUGIN_ROOT}` expanded, the exact JSON shape of stdin, and whether `session_id` is present in it.

- [ ] **Step 7: Lock the dispatch and write it down**

Create `docs/hook-dispatch.md` with the findings. If only one command form works on Windows, delete the other from `hooks.json` in the platform-specific task later. If **both** fire on one platform (duplicate guards), note it — Task 12 must then make the wrong-platform script exit 0 immediately after detecting it is on the wrong OS.

`bin/hook.sh` gets this guard at the top:

```sh
[ "$(uname -s)" = "Darwin" ] || exit 0
```

`bin/hook.ps1` gets:

```powershell
if ($env:OS -ne 'Windows_NT') { exit 0 }
```

- [ ] **Step 8: Commit**

```bash
git add .gitattributes .claude-plugin hooks bin LICENSE docs/hook-dispatch.md
git commit -m "Add plugin skeleton and lock hook dispatch mechanism"
```

---

### Task 2: Test harness and CI

**Files:**
- Create: `tests/assert.sh`, `tests/run.sh`, `tests/assert.ps1`, `tests/run.ps1`, `tests/test_smoke.sh`, `tests/test_smoke.ps1`, `.github/workflows/test.yml`

**Interfaces:**
- Produces: `assert_eq <actual> <expected> <name>` and `finish` in sh; `Assert-Eq -Actual -Expected -Name` and `Complete-Tests` in PowerShell. Every later test task uses exactly these names.

- [ ] **Step 1: Write `tests/assert.sh`**

```sh
# Minimal assertion harness. Sourced, not executed.
SA_TESTS=0
SA_FAILS=0

assert_eq() { # actual expected name
  SA_TESTS=$((SA_TESTS + 1))
  if [ "$1" = "$2" ]; then
    printf '  ok   %s\n' "$3"
  else
    printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$2" "$1"
    SA_FAILS=$((SA_FAILS + 1))
  fi
}

assert_true() { # command... name is last arg
  eval "$1"
  assert_eq "$?" "0" "$2"
}

finish() {
  printf '\n%s tests, %s failures\n' "$SA_TESTS" "$SA_FAILS"
  [ "$SA_FAILS" -eq 0 ]
}
```

- [ ] **Step 2: Write `tests/run.sh`**

```sh
#!/bin/sh
# Runs every tests/test_*.sh in a subshell. Exits non-zero if any fail.
cd "$(dirname "$0")" || exit 1
rc=0
for t in test_*.sh; do
  [ -f "$t" ] || continue
  printf '\n== %s ==\n' "$t"
  sh "$t" || rc=1
done
exit "$rc"
```

- [ ] **Step 3: Write `tests/assert.ps1`**

```powershell
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
```

- [ ] **Step 4: Write `tests/run.ps1`**

```powershell
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$rc = 0
Get-ChildItem -Path $here -Filter 'test_*.ps1' | ForEach-Object {
  Write-Host ""
  Write-Host "== $($_.Name) =="
  & powershell -NoProfile -ExecutionPolicy Bypass -File $_.FullName
  if ($LASTEXITCODE -ne 0) { $rc = 1 }
}
exit $rc
```

- [ ] **Step 5: Write smoke tests that prove the harness itself works**

`tests/test_smoke.sh`:

```sh
. "$(dirname "$0")/assert.sh"
assert_eq "a" "a" "harness reports equality"
finish
```

`tests/test_smoke.ps1`:

```powershell
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'assert.ps1')
Assert-Eq -Actual 'a' -Expected 'a' -Name 'harness reports equality'
Complete-Tests
```

- [ ] **Step 6: Run both, expect pass**

```bash
sh tests/run.sh
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run.ps1
```

Expected: `1 tests, 0 failures` from each, exit 0.

- [ ] **Step 7: Prove the harness can fail**

Temporarily change `assert_eq "a" "a"` to `assert_eq "a" "b"`, rerun, confirm exit code 1 and a `FAIL` line. Then change it back. A harness that cannot fail is worse than no harness.

- [ ] **Step 8: Write `.github/workflows/test.yml`**

```yaml
name: tests
on: [push, pull_request]
jobs:
  macos:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: sh tests/run.sh
  windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - run: powershell -NoProfile -ExecutionPolicy Bypass -File tests/run.ps1
```

- [ ] **Step 9: Commit**

```bash
git add tests .github
git commit -m "Add zero-dependency test harness and CI"
```

---

### Task 3: macOS power parsers

Parsers are tested against captured fixture text rather than live commands, because they are the part that silently rots when an OS changes its output format — and because CI on Linux cannot run `pmset`.

**Files:**
- Create: `lib/macos/platform.sh`, `tests/test_macos_parse.sh`, `tests/fixtures/pmset-batt-ac.txt`, `tests/fixtures/pmset-batt-low.txt`, `tests/fixtures/pmset-g-disabled.txt`, `tests/fixtures/pmset-g-absent.txt`

**Interfaces:**
- Produces:
  - `parse_batt` — reads `pmset -g batt` text on stdin, echoes `<source> <percent>` where source is `ac` or `battery`.
  - `parse_disablesleep` — reads `pmset -g` text on stdin, echoes the integer value, `0` when the key is absent.

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/pmset-batt-ac.txt`:

```
Now drawing from 'AC Power'
 -InternalBattery-0 (id=12648547)	100%; charged; 0:00 remaining present: true
```

`tests/fixtures/pmset-batt-low.txt`:

```
Now drawing from 'Battery Power'
 -InternalBattery-0 (id=12648547)	23%; discharging; 1:47 remaining present: true
```

`tests/fixtures/pmset-g-disabled.txt`:

```
System-wide power settings:
Currently in use:
 standbydelayhigh     86400
 sleep                1
 hibernatemode        3
 disablesleep         1
 displaysleep         10
```

`tests/fixtures/pmset-g-absent.txt`:

```
System-wide power settings:
Currently in use:
 standbydelayhigh     86400
 sleep                1
 hibernatemode        3
 displaysleep         10
```

- [ ] **Step 2: Write the failing test**

`tests/test_macos_parse.sh`:

```sh
HERE="$(dirname "$0")"
. "$HERE/assert.sh"
. "$HERE/../lib/macos/platform.sh"

assert_eq "$(parse_batt < "$HERE/fixtures/pmset-batt-ac.txt")" "ac 100" "AC at full charge"
assert_eq "$(parse_batt < "$HERE/fixtures/pmset-batt-low.txt")" "battery 23" "battery at 23 percent"
assert_eq "$(parse_disablesleep < "$HERE/fixtures/pmset-g-disabled.txt")" "1" "disablesleep set to 1"
assert_eq "$(parse_disablesleep < "$HERE/fixtures/pmset-g-absent.txt")" "0" "absent disablesleep defaults to 0"

finish
```

- [ ] **Step 3: Run it, expect failure**

```bash
sh tests/test_macos_parse.sh
```

Expected: FAIL — `lib/macos/platform.sh: No such file or directory`.

- [ ] **Step 4: Write the minimal implementation**

`lib/macos/platform.sh`:

```sh
# macOS power platform module. Sourced, not executed. bash 3.2 / POSIX sh safe.

# Reads `pmset -g batt` on stdin. Echoes "<ac|battery> <percent>".
parse_batt() {
  text=$(cat)
  case "$text" in
    *"'AC Power'"*) source=ac ;;
    *) source=battery ;;
  esac
  pct=$(printf '%s\n' "$text" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)%.*/\1/p' | head -1)
  # ponytail: no percentage in the output means no battery present; treat as full.
  [ -n "$pct" ] || pct=100
  printf '%s %s' "$source" "$pct"
}

# Reads `pmset -g` on stdin. Echoes the disablesleep value.
# macOS omits the key entirely until it has been set at least once, hence the default.
parse_disablesleep() {
  v=$(sed -n 's/^[[:space:]]*disablesleep[[:space:]][[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
  [ -n "$v" ] || v=0
  printf '%s' "$v"
}
```

- [ ] **Step 5: Run it, expect pass**

```bash
sh tests/test_macos_parse.sh
```

Expected: `4 tests, 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add lib/macos/platform.sh tests/test_macos_parse.sh tests/fixtures
git commit -m "Add macOS power output parsers with fixture tests"
```

---

### Task 4: Windows power parsers

**Files:**
- Create: `lib/windows/platform.ps1`, `tests/test_windows_parse.ps1`, `tests/fixtures/powercfg-lidaction.txt`, `tests/fixtures/powercfg-no-lidaction.txt`, `tests/fixtures/powercfg-a-s3.txt`, `tests/fixtures/powercfg-a-s0.txt`

**Interfaces:**
- Produces:
  - `Get-LidActionFromText -Text <string>` → `[pscustomobject]@{ Ac=<int>; Dc=<int>; Present=<bool> }`
  - `Get-PowerSourceFromStatus -BatteryStatus <int> -ChargePercent <int> -HasBattery <bool>` → `[pscustomobject]@{ Source='ac'|'battery'; Percent=<int> }`
  - `Test-ModernStandbyFromText -Text <string>` → `[bool]` — true when the machine is S0ix-only and lid coverage is unreliable.

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/powercfg-lidaction.txt` — a laptop with the setting present:

```
Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)
  Subgroup GUID: 4f971e89-eebd-4455-a8de-9e59040e7347  (Power buttons and lid)
    GUID Alias: SUB_BUTTONS
    Power Setting GUID: 5ca83367-6e45-459f-a27b-476b1d01c936  (Lid close action)
      GUID Alias: LIDACTION
      Possible Setting Index: 000
      Possible Setting Friendly Name: Do nothing
      Possible Setting Index: 001
      Possible Setting Friendly Name: Sleep
      Current AC Power Setting Index: 0x00000001
      Current DC Power Setting Index: 0x00000001
```

`tests/fixtures/powercfg-no-lidaction.txt` — captured verbatim from the dev machine, where the setting is absent:

```
Power Scheme GUID: 64a64f24-65b9-4b56-befd-5ec1eaced9b3  (Power saver)
  Subgroup GUID: 4f971e89-eebd-4455-a8de-9e59040e7347  (Power buttons and lid)
    GUID Alias: SUB_BUTTONS
    Power Setting GUID: a7066653-8d6c-40a8-910e-a1f54b84c7e5  (Start menu power button)
      GUID Alias: UIBUTTON_ACTION
      Possible Setting Index: 000
      Possible Setting Friendly Name: Sleep
    Current AC Power Setting Index: 0x00000000
    Current DC Power Setting Index: 0x00000000
```

`tests/fixtures/powercfg-a-s3.txt` — captured verbatim from the dev machine:

```
The following sleep states are available on this system:
    Standby (S3)
    Hibernate
    Fast Startup

The following sleep states are not available on this system:
    Standby (S0 Low Power Idle)
	The system firmware does not support this standby state.
```

`tests/fixtures/powercfg-a-s0.txt`:

```
The following sleep states are available on this system:
    Standby (S0 Low Power Idle)
    Hibernate
    Fast Startup

The following sleep states are not available on this system:
    Standby (S3)
	The system firmware does not support this standby state.
```

- [ ] **Step 2: Write the failing test**

`tests/test_windows_parse.ps1`:

```powershell
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'assert.ps1')
. (Join-Path $here '..\lib\windows\platform.ps1')

$lid = Get-LidActionFromText -Text (Get-Content (Join-Path $here 'fixtures\powercfg-lidaction.txt') -Raw)
Assert-Eq -Actual $lid.Present -Expected $true -Name 'lid setting detected as present'
Assert-Eq -Actual $lid.Ac -Expected 1 -Name 'AC lid action parsed as 1'
Assert-Eq -Actual $lid.Dc -Expected 1 -Name 'DC lid action parsed as 1'

$none = Get-LidActionFromText -Text (Get-Content (Join-Path $here 'fixtures\powercfg-no-lidaction.txt') -Raw)
Assert-Eq -Actual $none.Present -Expected $false -Name 'absent lid setting reported as absent'

$ac = Get-PowerSourceFromStatus -BatteryStatus 2 -ChargePercent 100 -HasBattery $true
Assert-Eq -Actual $ac.Source -Expected 'ac' -Name 'BatteryStatus 2 is AC'

$bat = Get-PowerSourceFromStatus -BatteryStatus 1 -ChargePercent 23 -HasBattery $true
Assert-Eq -Actual $bat.Source -Expected 'battery' -Name 'BatteryStatus 1 is battery'
Assert-Eq -Actual $bat.Percent -Expected 23 -Name 'charge percent passed through'

$desk = Get-PowerSourceFromStatus -BatteryStatus 0 -ChargePercent 0 -HasBattery $false
Assert-Eq -Actual $desk.Source -Expected 'ac' -Name 'no battery means AC'
Assert-Eq -Actual $desk.Percent -Expected 100 -Name 'no battery reports 100 percent'

$s3 = Test-ModernStandbyFromText -Text (Get-Content (Join-Path $here 'fixtures\powercfg-a-s3.txt') -Raw)
Assert-Eq -Actual $s3 -Expected $false -Name 'S3 machine is not modern standby'

$s0 = Test-ModernStandbyFromText -Text (Get-Content (Join-Path $here 'fixtures\powercfg-a-s0.txt') -Raw)
Assert-Eq -Actual $s0 -Expected $true -Name 'S0ix-only machine is modern standby'

Complete-Tests
```

- [ ] **Step 3: Run it, expect failure**

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_windows_parse.ps1
```

Expected: FAIL — the platform file does not exist.

- [ ] **Step 4: Write the minimal implementation**

`lib/windows/platform.ps1`:

```powershell
# Windows power platform module. Dot-sourced, not executed. PowerShell 5.1 safe.

function ConvertFrom-PowercfgHex {
  param([string]$Hex)
  return [Convert]::ToInt32($Hex.Substring(2), 16)
}

# Parses `powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION` output.
# Present is $false when the machine exposes no lid close action at all.
function Get-LidActionFromText {
  param([string]$Text)
  if ($Text -notmatch 'LIDACTION') {
    return [pscustomobject]@{ Ac = 0; Dc = 0; Present = $false }
  }
  $ac = [regex]::Match($Text, 'Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)')
  $dc = [regex]::Match($Text, 'Current DC Power Setting Index:\s*(0x[0-9a-fA-F]+)')
  if (-not $ac.Success -or -not $dc.Success) {
    return [pscustomobject]@{ Ac = 0; Dc = 0; Present = $false }
  }
  return [pscustomobject]@{
    Ac      = ConvertFrom-PowercfgHex -Hex $ac.Groups[1].Value
    Dc      = ConvertFrom-PowercfgHex -Hex $dc.Groups[1].Value
    Present = $true
  }
}

# Win32_Battery BatteryStatus: 1 means discharging. Everything else means
# mains power is present. A machine with no battery is always on mains.
function Get-PowerSourceFromStatus {
  param([int]$BatteryStatus, [int]$ChargePercent, [bool]$HasBattery)
  if (-not $HasBattery) {
    return [pscustomobject]@{ Source = 'ac'; Percent = 100 }
  }
  $src = 'ac'
  if ($BatteryStatus -eq 1) { $src = 'battery' }
  return [pscustomobject]@{ Source = $src; Percent = $ChargePercent }
}

# Parses `powercfg /a`. True when the machine offers S0 Low Power Idle but not
# S3, meaning lid close is firmware-driven and LIDACTION may not be honoured.
function Test-ModernStandbyFromText {
  param([string]$Text)
  $available = [regex]::Match($Text, '(?s)available on this system:(.*?)(?:\r?\n\r?\n|$)')
  if (-not $available.Success) { return $false }
  $block = $available.Groups[1].Value
  $hasS0 = $block -match 'S0 Low Power Idle'
  $hasS3 = $block -match 'Standby \(S3\)'
  return ($hasS0 -and -not $hasS3)
}
```

- [ ] **Step 5: Run it, expect pass**

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_windows_parse.ps1
```

Expected: `11 tests, 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add lib/windows/platform.ps1 tests/test_windows_parse.ps1 tests/fixtures
git commit -m "Add Windows power output parsers with fixture tests"
```

---

### Task 5: State and refcount module — POSIX sh

The heart of the crash-safety guarantee. Test it hardest.

**Files:**
- Create: `lib/state.sh`, `tests/test_state.sh`

**Interfaces:**
- Produces, all honouring `STAYAWAKE_HOME`:
  - `state_dir` — echoes the state directory path.
  - `guard_file <session_id> <kind>` — echoes the full path of a guard file.
  - `claim_baseline <text>` — creates `original.state` if and only if it does not exist. Returns 0 when this call created it, 1 when it already existed.
  - `read_baseline` — echoes the contents, empty if absent.
  - `clear_baseline` — removes it.
  - `guard_register <session_id> <kind> <guard_pid> <parent_pid>`
  - `guard_unregister <session_id> <kind>`
  - `guard_count` — echoes the number of guard files.
  - `reap_dead_guards` — removes guard files whose recorded PID is not alive.

- [ ] **Step 1: Write the failing test**

`tests/test_state.sh`:

```sh
HERE="$(dirname "$0")"
. "$HERE/assert.sh"

STAYAWAKE_HOME="${TMPDIR:-/tmp}/stayawake-test-$$"
export STAYAWAKE_HOME
rm -rf "$STAYAWAKE_HOME"

. "$HERE/../lib/state.sh"

# --- baseline is claimed exactly once ---
claim_baseline "disablesleep=0"
assert_eq "$?" "0" "first claim succeeds"
claim_baseline "disablesleep=9"
assert_eq "$?" "1" "second claim is refused"
assert_eq "$(read_baseline)" "disablesleep=0" "baseline holds the first writer's value"

# --- refcount ---
assert_eq "$(guard_count)" "0" "no guards at start"
guard_register "sess-a" "turn" "$$" "$$"
assert_eq "$(guard_count)" "1" "one guard after register"
guard_register "sess-a" "pin" "$$" "$$"
assert_eq "$(guard_count)" "2" "pin and turn coexist in one session"
guard_unregister "sess-a" "turn"
assert_eq "$(guard_count)" "1" "unregister removes only its own file"

# --- dead guards are reaped, live ones are not ---
# PID 999999 is above the default pid_max on both platforms, so it is never alive.
guard_register "sess-dead" "turn" "999999" "999999"
assert_eq "$(guard_count)" "2" "dead guard counted before reaping"
reap_dead_guards
assert_eq "$(guard_count)" "1" "dead guard reaped, live guard kept"

# --- teardown clears the baseline ---
guard_unregister "sess-a" "pin"
assert_eq "$(guard_count)" "0" "all guards gone"
clear_baseline
assert_eq "$(read_baseline)" "" "baseline cleared"

rm -rf "$STAYAWAKE_HOME"
finish
```

- [ ] **Step 2: Run it, expect failure**

```bash
sh tests/test_state.sh
```

Expected: FAIL — `lib/state.sh: No such file or directory`.

- [ ] **Step 3: Write the minimal implementation**

`lib/state.sh`:

```sh
# Shared state for stayawake guards. Sourced, not executed.

state_dir() {
  printf '%s' "${STAYAWAKE_HOME:-$HOME/.stayawake}"
}

guards_dir() {
  printf '%s/guards' "$(state_dir)"
}

guard_file() { # session_id kind
  printf '%s/%s-%s' "$(guards_dir)" "$1" "$2"
}

baseline_file() {
  printf '%s/original.state' "$(state_dir)"
}

_ensure_dirs() {
  mkdir -p "$(guards_dir)" 2>/dev/null
}

# Creates the baseline only if absent. Returns 0 if this call created it.
# The subshell keeps `set -C` (noclobber) from leaking into the caller; noclobber
# makes `>` fail atomically when the file already exists, which is the whole trick.
claim_baseline() { # text
  _ensure_dirs
  if ( set -C; printf '%s\n' "$1" > "$(baseline_file)" ) 2>/dev/null; then
    return 0
  fi
  return 1
}

read_baseline() {
  [ -f "$(baseline_file)" ] || return 0
  cat "$(baseline_file)"
}

clear_baseline() {
  rm -f "$(baseline_file)"
}

guard_register() { # session_id kind guard_pid parent_pid
  _ensure_dirs
  printf 'guard_pid=%s\nparent_pid=%s\n' "$3" "$4" > "$(guard_file "$1" "$2")"
}

guard_unregister() { # session_id kind
  rm -f "$(guard_file "$1" "$2")"
}

guard_count() {
  n=0
  for f in "$(guards_dir)"/*; do
    [ -f "$f" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

_pid_alive() { # pid
  kill -0 "$1" 2>/dev/null
}

# ponytail: PID reuse could in principle keep a stale guard file alive. The
# window is seconds and the cost is one extra poll cycle, so it is ignored.
reap_dead_guards() {
  for f in "$(guards_dir)"/*; do
    [ -f "$f" ] || continue
    pid=$(sed -n 's/^guard_pid=\([0-9][0-9]*\)$/\1/p' "$f" | head -1)
    [ -n "$pid" ] || continue
    _pid_alive "$pid" || rm -f "$f"
  done
}
```

Note the `read_baseline` newline: `claim_baseline` writes a trailing newline and `$(...)` strips it, so `assert_eq "$(read_baseline)" "disablesleep=0"` matches.

- [ ] **Step 4: Run it, expect pass**

```bash
sh tests/test_state.sh
```

Expected: `11 tests, 0 failures`.

- [ ] **Step 5: Verify the atomic claim survives concurrency**

Add to `tests/test_state.sh` before `finish`:

```sh
# --- twenty concurrent claimers, exactly one wins ---
rm -rf "$STAYAWAKE_HOME"
i=0
while [ "$i" -lt 20 ]; do
  ( claim_baseline "writer=$i" && echo won >> "${TMPDIR:-/tmp}/sa-race-$$" ) &
  i=$((i + 1))
done
wait
assert_eq "$(wc -l < "${TMPDIR:-/tmp}/sa-race-$$" | tr -d ' ')" "1" "exactly one concurrent claimer wins"
rm -f "${TMPDIR:-/tmp}/sa-race-$$"
```

Run again. Expected: `12 tests, 0 failures`. If this fails, `set -C` is not atomic on the filesystem under test and the implementation must switch to `mkdir` as the lock primitive — `mkdir` is atomic everywhere.

- [ ] **Step 6: Commit**

```bash
git add lib/state.sh tests/test_state.sh
git commit -m "Add POSIX sh state and refcount module"
```

---

### Task 6: State and refcount module — PowerShell

Same semantics as Task 5, independently implemented and independently tested. Read Task 5's interface list before starting; the function names differ by PowerShell convention but the behaviour is identical.

**Files:**
- Create: `lib/state.ps1`, `tests/test_state.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: `Get-StateDir`, `Get-GuardFile -SessionId -Kind`, `Claim-Baseline -Text` → `[bool]`, `Read-Baseline` → `[string]`, `Clear-Baseline`, `Register-Guard -SessionId -Kind -GuardPid -ParentPid`, `Unregister-Guard -SessionId -Kind`, `Get-GuardCount` → `[int]`, `Remove-DeadGuards`.

- [ ] **Step 1: Write the failing test**

`tests/test_state.ps1`:

```powershell
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'assert.ps1')

$env:STAYAWAKE_HOME = Join-Path $env:TEMP "stayawake-test-$PID"
if (Test-Path $env:STAYAWAKE_HOME) { Remove-Item $env:STAYAWAKE_HOME -Recurse -Force }

. (Join-Path $here '..\lib\state.ps1')

Assert-Eq -Actual (Claim-Baseline -Text 'lidAc=1') -Expected $true  -Name 'first claim succeeds'
Assert-Eq -Actual (Claim-Baseline -Text 'lidAc=9') -Expected $false -Name 'second claim is refused'
Assert-Eq -Actual (Read-Baseline) -Expected 'lidAc=1' -Name "baseline holds the first writer's value"

Assert-Eq -Actual (Get-GuardCount) -Expected 0 -Name 'no guards at start'
Register-Guard -SessionId 'sess-a' -Kind 'turn' -GuardPid $PID -ParentPid $PID
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'one guard after register'
Register-Guard -SessionId 'sess-a' -Kind 'pin' -GuardPid $PID -ParentPid $PID
Assert-Eq -Actual (Get-GuardCount) -Expected 2 -Name 'pin and turn coexist in one session'
Unregister-Guard -SessionId 'sess-a' -Kind 'turn'
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'unregister removes only its own file'

Register-Guard -SessionId 'sess-dead' -Kind 'turn' -GuardPid 999999 -ParentPid 999999
Assert-Eq -Actual (Get-GuardCount) -Expected 2 -Name 'dead guard counted before reaping'
Remove-DeadGuards
Assert-Eq -Actual (Get-GuardCount) -Expected 1 -Name 'dead guard reaped, live guard kept'

Unregister-Guard -SessionId 'sess-a' -Kind 'pin'
Assert-Eq -Actual (Get-GuardCount) -Expected 0 -Name 'all guards gone'
Clear-Baseline
Assert-Eq -Actual (Read-Baseline) -Expected '' -Name 'baseline cleared'

Remove-Item $env:STAYAWAKE_HOME -Recurse -Force
Complete-Tests
```

- [ ] **Step 2: Run it, expect failure**

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_state.ps1
```

Expected: FAIL — the state file does not exist.

- [ ] **Step 3: Write the minimal implementation**

`lib/state.ps1`:

```powershell
# Shared state for stayawake guards. Dot-sourced, not executed.

function Get-StateDir {
  if ($env:STAYAWAKE_HOME) { return $env:STAYAWAKE_HOME }
  return (Join-Path $env:USERPROFILE '.stayawake')
}

function Get-GuardsDir { return (Join-Path (Get-StateDir) 'guards') }

function Get-GuardFile {
  param([string]$SessionId, [string]$Kind)
  return (Join-Path (Get-GuardsDir) "$SessionId-$Kind")
}

function Get-BaselineFile { return (Join-Path (Get-StateDir) 'original.state') }

function Initialize-StateDirs {
  New-Item -ItemType Directory -Force -Path (Get-GuardsDir) | Out-Null
}

# CreateNew throws IOException when the file exists. That throw is the atomic
# test-and-set; do not replace it with a Test-Path check, which races.
function Claim-Baseline {
  param([string]$Text)
  Initialize-StateDirs
  try {
    $fs = [System.IO.File]::Open((Get-BaselineFile), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
  } catch [System.IO.IOException] {
    return $false
  }
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $fs.Write($bytes, 0, $bytes.Length)
  } finally {
    $fs.Dispose()
  }
  return $true
}

function Read-Baseline {
  $f = Get-BaselineFile
  if (-not (Test-Path $f)) { return '' }
  return ([System.IO.File]::ReadAllText($f)).Trim()
}

function Clear-Baseline {
  $f = Get-BaselineFile
  if (Test-Path $f) { Remove-Item $f -Force }
}

function Register-Guard {
  param([string]$SessionId, [string]$Kind, [int]$GuardPid, [int]$ParentPid)
  Initialize-StateDirs
  Set-Content -Path (Get-GuardFile -SessionId $SessionId -Kind $Kind) `
              -Value "guard_pid=$GuardPid`nparent_pid=$ParentPid" -Encoding utf8
}

function Unregister-Guard {
  param([string]$SessionId, [string]$Kind)
  $f = Get-GuardFile -SessionId $SessionId -Kind $Kind
  if (Test-Path $f) { Remove-Item $f -Force }
}

function Get-GuardCount {
  $d = Get-GuardsDir
  if (-not (Test-Path $d)) { return 0 }
  return @(Get-ChildItem -Path $d -File).Count
}

function Test-PidAlive {
  param([int]$ProcessId)
  $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  return ($null -ne $p)
}

# ponytail: PID reuse could keep a stale guard file alive for one poll cycle.
# Accepted; the cost is bounded and the fix would need a start-time comparison.
function Remove-DeadGuards {
  $d = Get-GuardsDir
  if (-not (Test-Path $d)) { return }
  foreach ($f in Get-ChildItem -Path $d -File) {
    $m = [regex]::Match((Get-Content $f.FullName -Raw), 'guard_pid=(\d+)')
    if (-not $m.Success) { continue }
    if (-not (Test-PidAlive -ProcessId ([int]$m.Groups[1].Value))) {
      Remove-Item $f.FullName -Force
    }
  }
}
```

- [ ] **Step 4: Run it, expect pass**

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_state.ps1
```

Expected: `11 tests, 0 failures`.

- [ ] **Step 5: Verify the atomic claim under concurrency**

Add before `Complete-Tests`:

```powershell
Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue
$statePath = Join-Path $here '..\lib\state.ps1'
$jobs = 1..10 | ForEach-Object {
  Start-Job -ArgumentList $statePath, $env:STAYAWAKE_HOME, $_ -ScriptBlock {
    param($sp, $home_, $i)
    $env:STAYAWAKE_HOME = $home_
    . $sp
    if (Claim-Baseline -Text "writer=$i") { 'won' } else { 'lost' }
  }
}
$results = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job
Assert-Eq -Actual (@($results | Where-Object { $_ -eq 'won' }).Count) -Expected 1 `
          -Name 'exactly one concurrent claimer wins'
```

Run again. Expected: `12 tests, 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add lib/state.ps1 tests/test_state.ps1
git commit -m "Add PowerShell state and refcount module"
```

---

### Task 7: Ancestor PID resolution

The guard must watch the Claude Code process, not the short-lived shell that ran the hook. If the terminal is killed with `SIGKILL`, no hook fires and this poll is the only thing that triggers restore. Getting the wrong PID silently disables the main crash-safety mechanism.

**Files:**
- Create: `lib/ancestor.sh`, `lib/ancestor.ps1`, `tests/test_ancestor.sh`, `tests/test_ancestor.ps1`

**Interfaces:**
- Produces: `find_claude_pid <start_pid>` (sh) and `Find-ClaudePid -StartPid <int>` (ps1). Both walk up the process tree at most 6 levels looking for a process whose name contains `claude`, and fall back to the immediate parent of `start_pid` if none is found.

- [ ] **Step 1: Write the failing test for sh**

`tests/test_ancestor.sh`:

```sh
HERE="$(dirname "$0")"
. "$HERE/assert.sh"
. "$HERE/../lib/ancestor.sh"

# The walker is pure given an injectable parent-lookup and name-lookup, so the
# tree is faked rather than requiring a real claude process.
_ppid_of() { case "$1" in 100) echo 200 ;; 200) echo 300 ;; 300) echo 1 ;; *) echo 1 ;; esac; }
_name_of() { case "$1" in 100) echo sh ;; 200) echo bash ;; 300) echo claude ;; *) echo init ;; esac; }

assert_eq "$(find_claude_pid 100)" "300" "walks up to the claude process"

_name_of() { echo bash; }
assert_eq "$(find_claude_pid 100)" "200" "falls back to immediate parent when no claude found"

finish
```

- [ ] **Step 2: Run it, expect failure**

```bash
sh tests/test_ancestor.sh
```

Expected: FAIL — file not found.

- [ ] **Step 3: Write the implementation**

`lib/ancestor.sh`:

```sh
# Walks the process tree to find the Claude Code process the guard should watch.
# _ppid_of and _name_of are overridable so the walker can be tested without a
# real process tree.

_ppid_of() { # pid
  ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '
}

_name_of() { # pid
  ps -o comm= -p "$1" 2>/dev/null | tr -d ' '
}

find_claude_pid() { # start_pid
  cur="$1"
  fallback=$(_ppid_of "$cur")
  [ -n "$fallback" ] || fallback="$cur"
  i=0
  while [ "$i" -lt 6 ]; do
    cur=$(_ppid_of "$cur")
    [ -n "$cur" ] || break
    [ "$cur" = "1" ] && break
    [ "$cur" = "0" ] && break
    case "$(_name_of "$cur")" in
      *claude*) printf '%s' "$cur"; return 0 ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$fallback"
}
```

- [ ] **Step 4: Run it, expect pass**

```bash
sh tests/test_ancestor.sh
```

Expected: `2 tests, 0 failures`.

- [ ] **Step 5: Write the failing test for PowerShell**

`tests/test_ancestor.ps1`:

```powershell
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'assert.ps1')
. (Join-Path $here '..\lib\ancestor.ps1')

$tree = @{ 100 = @{ Parent = 200; Name = 'powershell' }
           200 = @{ Parent = 300; Name = 'cmd' }
           300 = @{ Parent = 1;   Name = 'claude' } }

$lookup = { param($id) if ($tree.ContainsKey($id)) { return $tree[$id] } else { return $null } }

Assert-Eq -Actual (Find-ClaudePid -StartPid 100 -Lookup $lookup) -Expected 300 `
          -Name 'walks up to the claude process'

$flat = @{ 100 = @{ Parent = 200; Name = 'powershell' }
           200 = @{ Parent = 1;   Name = 'cmd' } }
$flatLookup = { param($id) if ($flat.ContainsKey($id)) { return $flat[$id] } else { return $null } }

Assert-Eq -Actual (Find-ClaudePid -StartPid 100 -Lookup $flatLookup) -Expected 200 `
          -Name 'falls back to immediate parent when no claude found'

Complete-Tests
```

- [ ] **Step 6: Run it, expect failure, then implement**

`lib/ancestor.ps1`:

```powershell
# Walks the process tree to find the Claude Code process the guard should watch.
# Lookup is injectable so the walker is testable without a real process tree.

function Get-ProcessNode {
  param([int]$ProcessId)
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
  if ($null -eq $p) { return $null }
  return @{ Parent = [int]$p.ParentProcessId; Name = [string]$p.Name }
}

function Find-ClaudePid {
  param([int]$StartPid, [scriptblock]$Lookup = ${function:Get-ProcessNode})
  $node = & $Lookup $StartPid
  if ($null -eq $node) { return $StartPid }
  $fallback = $node.Parent
  $cur = $StartPid
  for ($i = 0; $i -lt 6; $i++) {
    $n = & $Lookup $cur
    if ($null -eq $n) { break }
    $cur = $n.Parent
    if ($cur -le 1) { break }
    $parentNode = & $Lookup $cur
    if ($null -eq $parentNode) { break }
    if ($parentNode.Name -like '*claude*') { return $cur }
  }
  return $fallback
}
```

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_ancestor.ps1`
Expected: `2 tests, 0 failures`.

- [ ] **Step 7: Sanity-check against the real tree**

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". .\lib\ancestor.ps1; Find-ClaudePid -StartPid \$PID"
```

Expected: a PID that is not `$PID` itself. Confirm with `Get-Process -Id <result>` that the name is plausible. This is a smoke check, not an assertion — the result depends on how the command was launched.

- [ ] **Step 8: Commit**

```bash
git add lib/ancestor.sh lib/ancestor.ps1 tests/test_ancestor.sh tests/test_ancestor.ps1
git commit -m "Add process-tree walker to locate the Claude Code PID"
```

---

### Task 8: macOS apply, restore, and guard loop

**Files:**
- Modify: `lib/macos/platform.sh` (append apply/restore/battery)
- Create: `bin/guard.sh`, `tests/test_macos_guard.sh`

**Interfaces:**
- Consumes: `parse_batt`, `parse_disablesleep` (Task 3); all of `lib/state.sh` (Task 5); `find_claude_pid` (Task 7).
- Produces: `read_state` → echoes `disablesleep=<n>`; `apply_state` ; `restore_state <baseline_text>` ; `power_source` → echoes `<ac|battery> <percent>`. And `bin/guard.sh <session_id> <kind> <parent_pid>`.

- [ ] **Step 1: Append the state verbs to `lib/macos/platform.sh`**

```sh
# --- live system access (not unit tested; the parsers above are) ---

read_state() {
  printf 'disablesleep=%s' "$(pmset -g | parse_disablesleep)"
}

power_source() {
  pmset -g batt | parse_batt
}

apply_state() {
  # Requires the sudoers grant installed by `stayawake setup`. Without it this
  # prompts and hangs, so setup is what makes lid coverage available at all.
  sudo -n pmset -a disablesleep 1 2>/dev/null
}

restore_state() { # baseline_text
  v=$(printf '%s' "$1" | sed -n 's/^disablesleep=\([0-9][0-9]*\)$/\1/p' | head -1)
  [ -n "$v" ] || v=0
  sudo -n pmset -a disablesleep "$v" 2>/dev/null
}

lid_available() {
  sudo -n pmset -g >/dev/null 2>&1
}
```

- [ ] **Step 2: Write the failing guard test**

`tests/test_macos_guard.sh` — tests the guard's *decisions*, with the platform verbs stubbed. The real `pmset` is never called.

```sh
HERE="$(dirname "$0")"
. "$HERE/assert.sh"

STAYAWAKE_HOME="${TMPDIR:-/tmp}/stayawake-guardtest-$$"
export STAYAWAKE_HOME
rm -rf "$STAYAWAKE_HOME"

# Stub platform: record calls to a log instead of touching the system.
STUB_LOG="$STAYAWAKE_HOME/calls.log"
mkdir -p "$STAYAWAKE_HOME"

export STAYAWAKE_PLATFORM_STUB="$HERE/stub_platform.sh"
cat > "$STAYAWAKE_PLATFORM_STUB" <<'EOF'
read_state()    { printf 'disablesleep=0'; }
apply_state()   { echo apply >> "$STUB_LOG"; }
restore_state() { echo "restore:$1" >> "$STUB_LOG"; }
power_source()  { printf '%s' "${STUB_POWER:-ac 100}"; }
lid_available() { return 0; }
EOF

export STAYAWAKE_POLL=1
export STUB_LOG

# --- a guard on low battery refuses to engage and leaves no trace ---
STUB_POWER="battery 12"
export STUB_POWER
sh "$HERE/../bin/guard.sh" "sess-low" "turn" "$$"
assert_eq "$(cat "$STUB_LOG" 2>/dev/null)" "" "low battery guard never applies"
assert_eq "$(ls "$STAYAWAKE_HOME/guards" 2>/dev/null | wc -l | tr -d ' ')" "0" "low battery guard registers nothing"

# --- a guard on AC applies, then restores when its guard file is deleted ---
STUB_POWER="ac 100"
sh "$HERE/../bin/guard.sh" "sess-ac" "turn" "$$" &
GUARD_SHELL=$!
sleep 2
assert_eq "$(grep -c '^apply$' "$STUB_LOG")" "1" "AC guard applied once"
rm -f "$STAYAWAKE_HOME/guards/sess-ac-turn"
sleep 3
assert_eq "$(grep -c '^restore:disablesleep=0$' "$STUB_LOG")" "1" "guard restored after its file was removed"
assert_eq "$(ls "$STAYAWAKE_HOME"/original.state 2>/dev/null)" "" "baseline cleared by last guard out"
wait "$GUARD_SHELL" 2>/dev/null

rm -rf "$STAYAWAKE_HOME"
finish
```

- [ ] **Step 3: Run it, expect failure**

```bash
sh tests/test_macos_guard.sh
```

Expected: FAIL — `bin/guard.sh` does not exist.

- [ ] **Step 4: Write `bin/guard.sh`**

```sh
#!/bin/sh
# usage: guard.sh <session_id> <kind> <parent_pid>
# Holds the machine awake until the parent dies, its guard file is removed,
# or the battery drops below the floor. Restores on every exit path.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/lib/state.sh"
if [ -n "${STAYAWAKE_PLATFORM_STUB:-}" ]; then
  . "$STAYAWAKE_PLATFORM_STUB"
else
  . "$ROOT/lib/macos/platform.sh"
fi

SESSION="$1"
KIND="$2"
PARENT="$3"
POLL="${STAYAWAKE_POLL:-30}"
CAFF_PID=""

config_get() { # key default
  f="$(state_dir)/config.json"
  [ -f "$f" ] || { printf '%s' "$2"; return; }
  v=$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$f" | head -1)
  [ -n "$v" ] || v="$2"
  printf '%s' "$v"
}

FLOOR="$(config_get batteryFloor 30)"

on_battery_below_floor() {
  set -- $(power_source)
  [ "$1" = "battery" ] && [ "$2" -lt "$FLOOR" ]
}

# Checked BEFORE registering or applying, so a turn started on a flat battery
# does not engage the override and release it one poll later.
if on_battery_below_floor; then
  exit 0
fi

cleanup() {
  guard_unregister "$SESSION" "$KIND"
  reap_dead_guards
  if [ "$(guard_count)" -eq 0 ]; then
    restore_state "$(read_baseline)"
    clear_baseline
  fi
  [ -n "$CAFF_PID" ] && kill "$CAFF_PID" 2>/dev/null
  exit 0
}

claim_baseline "$(read_state)" || true
guard_register "$SESSION" "$KIND" "$$" "$PARENT"
# The trap is armed only after registering. Arming it earlier would let an early
# exit run a restore on a baseline this guard does not own.
trap cleanup EXIT INT TERM HUP

apply_state

# -i blocks system idle sleep and deliberately leaves display sleep alone.
# -w makes caffeinate exit when the parent does, so it can never outlive it.
if command -v caffeinate >/dev/null 2>&1; then
  caffeinate -i -s -w "$PARENT" &
  CAFF_PID=$!
fi

while :; do
  kill -0 "$PARENT" 2>/dev/null || break
  [ -f "$(guard_file "$SESSION" "$KIND")" ] || break
  on_battery_below_floor && break
  reap_dead_guards
  sleep "$POLL"
done
# EXIT trap runs cleanup.
```

- [ ] **Step 5: Run it, expect pass**

```bash
sh tests/test_macos_guard.sh
```

Expected: `5 tests, 0 failures`.

- [ ] **Step 6: Prove the SIGKILL path restores**

Add before `finish`:

```sh
# --- killing the parent triggers restore via the poll ---
: > "$STUB_LOG"
sh -c 'sleep 60' &
FAKE_PARENT=$!
sh "$HERE/../bin/guard.sh" "sess-kill" "turn" "$FAKE_PARENT" &
sleep 2
kill -9 "$FAKE_PARENT"
sleep 3
assert_eq "$(grep -c '^restore:' "$STUB_LOG")" "1" "guard restored after parent was SIGKILLed"
```

Run again. Expected: `6 tests, 0 failures`. This test is the crash-safety guarantee; if it does not pass, nothing else in the plan matters.

- [ ] **Step 7: Commit**

```bash
git add lib/macos/platform.sh bin/guard.sh tests/test_macos_guard.sh
git commit -m "Add macOS guard loop with restore on every exit path"
```

---

### Task 9: Windows apply, restore, and guard loop

**Files:**
- Create: `lib/windows/lid.ps1`, `bin/guard.ps1`, `tests/test_windows_guard.ps1`
- Modify: `lib/windows/platform.ps1` (append live-access verbs)

**Interfaces:**
- Consumes: Task 4 parsers, Task 6 state module, Task 7 walker.
- Produces: `Get-CurrentState` → `[string]` `lidAc=<n>;lidDc=<n>`; `Invoke-ApplyState`; `Invoke-RestoreState -Baseline <string>`; `Get-PowerSource` → the Task 4 object. `lib/windows/lid.ps1 -Action Disable|Restore` is the *elevated* script the scheduled tasks run.

- [ ] **Step 1: Append the live-access verbs to `lib/windows/platform.ps1`**

```powershell
# --- live system access (not unit tested; the parsers above are) ---

$script:SubButtons = '4f971e89-eebd-4455-a8de-9e59040e7347'
$script:LidAction  = '5ca83367-6e45-459f-a27b-476b1d01c936'

function Get-LidActionLive {
  $text = (powercfg /query SCHEME_CURRENT $script:SubButtons $script:LidAction 2>&1 | Out-String)
  return Get-LidActionFromText -Text $text
}

function Get-CurrentState {
  $lid = Get-LidActionLive
  if (-not $lid.Present) { return 'lidAc=-1;lidDc=-1' }
  return "lidAc=$($lid.Ac);lidDc=$($lid.Dc)"
}

function Get-PowerSource {
  $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $b) {
    return Get-PowerSourceFromStatus -BatteryStatus 0 -ChargePercent 0 -HasBattery $false
  }
  return Get-PowerSourceFromStatus -BatteryStatus ([int]$b.BatteryStatus) `
                                   -ChargePercent ([int]$b.EstimatedChargeRemaining) `
                                   -HasBattery $true
}

# The guard is unprivileged; the elevated scheduled tasks do the actual writes.
function Invoke-ApplyState {
  schtasks /run /tn "StayAwake\Disable" | Out-Null
}

function Invoke-RestoreState {
  param([string]$Baseline)
  Set-Content -Path (Join-Path (Get-StateDir) 'restore.state') -Value $Baseline -Encoding utf8
  schtasks /run /tn "StayAwake\Restore" | Out-Null
}
```

- [ ] **Step 2: Write `lib/windows/lid.ps1` — the elevated half**

```powershell
# Runs elevated, launched only by the StayAwake scheduled tasks.
# Disable: set lid close action to "do nothing" on both AC and battery.
# Restore: write back the values recorded in restore.state, or Sleep(1) if absent.
param([ValidateSet('Disable','Restore')][string]$Action)

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'lib\state.ps1')
. (Join-Path $root 'lib\windows\platform.ps1')

$sub = '4f971e89-eebd-4455-a8de-9e59040e7347'
$lid = '5ca83367-6e45-459f-a27b-476b1d01c936'

function Set-LidAction {
  param([int]$Ac, [int]$Dc)
  if ($Ac -ge 0) { powercfg /setacvalueindex SCHEME_CURRENT $sub $lid $Ac | Out-Null }
  if ($Dc -ge 0) { powercfg /setdcvalueindex SCHEME_CURRENT $sub $lid $Dc | Out-Null }
  powercfg /setactive SCHEME_CURRENT | Out-Null
}

if ($Action -eq 'Disable') {
  $cur = Get-LidActionLive
  if (-not $cur.Present) { exit 0 }
  Set-LidAction -Ac 0 -Dc 0
  exit 0
}

$file = Join-Path (Get-StateDir) 'restore.state'
$ac = 1; $dc = 1
if (Test-Path $file) {
  $text = (Get-Content $file -Raw)
  $m = [regex]::Match($text, 'lidAc=(-?\d+);lidDc=(-?\d+)')
  if ($m.Success) { $ac = [int]$m.Groups[1].Value; $dc = [int]$m.Groups[2].Value }
}
Set-LidAction -Ac $ac -Dc $dc
exit 0
```

Note `-1` means "the setting was absent on this machine" and both functions skip it — never write a value to a setting the machine does not have.

- [ ] **Step 3: Write the failing guard test**

`tests/test_windows_guard.ps1` — same shape as the macOS test, with the platform verbs stubbed.

```powershell
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'assert.ps1')

$env:STAYAWAKE_HOME = Join-Path $env:TEMP "stayawake-guardtest-$PID"
if (Test-Path $env:STAYAWAKE_HOME) { Remove-Item $env:STAYAWAKE_HOME -Recurse -Force }
New-Item -ItemType Directory -Force -Path $env:STAYAWAKE_HOME | Out-Null

$stub = Join-Path $env:STAYAWAKE_HOME 'stub_platform.ps1'
$env:STAYAWAKE_STUB_LOG = Join-Path $env:STAYAWAKE_HOME 'calls.log'
@'
function Get-CurrentState { return 'lidAc=1;lidDc=1' }
function Invoke-ApplyState { Add-Content -Path $env:STAYAWAKE_STUB_LOG -Value 'apply' }
function Invoke-RestoreState { param([string]$Baseline) Add-Content -Path $env:STAYAWAKE_STUB_LOG -Value "restore:$Baseline" }
function Get-PowerSource {
  $p = $env:STAYAWAKE_STUB_POWER
  if (-not $p) { $p = 'ac 100' }
  $parts = $p.Split(' ')
  return [pscustomobject]@{ Source = $parts[0]; Percent = [int]$parts[1] }
}
function Set-IdleAssertion { param([bool]$On) }
'@ | Set-Content -Path $stub -Encoding utf8

$env:STAYAWAKE_PLATFORM_STUB = $stub
$env:STAYAWAKE_POLL = '1'
$guard = Join-Path $here '..\bin\guard.ps1'

# --- low battery: no apply, no registration ---
$env:STAYAWAKE_STUB_POWER = 'battery 12'
& powershell -NoProfile -ExecutionPolicy Bypass -File $guard -SessionId 'sess-low' -Kind 'turn' -ParentPid $PID
$log = ''
if (Test-Path $env:STAYAWAKE_STUB_LOG) { $log = (Get-Content $env:STAYAWAKE_STUB_LOG -Raw) }
Assert-Eq -Actual $log -Expected '' -Name 'low battery guard never applies'
Assert-Eq -Actual (@(Get-ChildItem (Join-Path $env:STAYAWAKE_HOME 'guards') -File -ErrorAction SilentlyContinue).Count) `
          -Expected 0 -Name 'low battery guard registers nothing'

# --- AC: applies, then restores when its guard file is deleted ---
$env:STAYAWAKE_STUB_POWER = 'ac 100'
$p = Start-Process powershell -PassThru -WindowStyle Hidden `
     -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$guard,
                   '-SessionId','sess-ac','-Kind','turn','-ParentPid',$PID
Start-Sleep -Seconds 3
$log = Get-Content $env:STAYAWAKE_STUB_LOG -Raw
Assert-Eq -Actual (@([regex]::Matches($log,'^apply$','Multiline')).Count) -Expected 1 -Name 'AC guard applied once'
Remove-Item (Join-Path $env:STAYAWAKE_HOME 'guards\sess-ac-turn') -Force
Start-Sleep -Seconds 4
$log = Get-Content $env:STAYAWAKE_STUB_LOG -Raw
Assert-Eq -Actual (@([regex]::Matches($log,'restore:lidAc=1;lidDc=1')).Count) -Expected 1 `
          -Name 'guard restored after its file was removed'
Assert-Eq -Actual (Test-Path (Join-Path $env:STAYAWAKE_HOME 'original.state')) -Expected $false `
          -Name 'baseline cleared by last guard out'

Remove-Item $env:STAYAWAKE_HOME -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
```

- [ ] **Step 4: Run it, expect failure**

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_windows_guard.ps1
```

Expected: FAIL — `bin/guard.ps1` does not exist.

- [ ] **Step 5: Write `bin/guard.ps1`**

```powershell
param(
  [Parameter(Mandatory=$true)][string]$SessionId,
  [Parameter(Mandatory=$true)][string]$Kind,
  [Parameter(Mandatory=$true)][int]$ParentPid
)

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\state.ps1')
if ($env:STAYAWAKE_PLATFORM_STUB) {
  . $env:STAYAWAKE_PLATFORM_STUB
} else {
  . (Join-Path $root 'lib\windows\platform.ps1')

  Add-Type -Namespace SA -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@

  # ES_DISPLAY_REQUIRED is deliberately omitted so the screen still sleeps.
  function Set-IdleAssertion {
    param([bool]$On)
    $ES_CONTINUOUS      = [uint32]0x80000000
    $ES_SYSTEM_REQUIRED = [uint32]0x00000001
    if ($On) {
      [SA.Native]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) | Out-Null
    } else {
      [SA.Native]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
    }
  }
}

$poll = 30
if ($env:STAYAWAKE_POLL) { $poll = [int]$env:STAYAWAKE_POLL }

$floor = 30
$cfg = Join-Path (Get-StateDir) 'config.json'
if (Test-Path $cfg) {
  $m = [regex]::Match((Get-Content $cfg -Raw), '"batteryFloor"\s*:\s*(\d+)')
  if ($m.Success) { $floor = [int]$m.Groups[1].Value }
}

function Test-BelowFloor {
  $p = Get-PowerSource
  return (($p.Source -eq 'battery') -and ($p.Percent -lt $floor))
}

# Checked before registering or applying, so a turn started on a flat battery
# does not engage the override and release it one poll later.
if (Test-BelowFloor) { exit 0 }

Claim-Baseline -Text (Get-CurrentState) | Out-Null
Register-Guard -SessionId $SessionId -Kind $Kind -GuardPid $PID -ParentPid $ParentPid

try {
  Invoke-ApplyState
  Set-IdleAssertion -On $true

  while ($true) {
    if (-not (Test-PidAlive -ProcessId $ParentPid)) { break }
    if (-not (Test-Path (Get-GuardFile -SessionId $SessionId -Kind $Kind))) { break }
    if (Test-BelowFloor) { break }
    Remove-DeadGuards
    Start-Sleep -Seconds $poll
  }
}
finally {
  # finally does not run if this process is SIGKILLed. That case is covered by
  # sibling guards' Remove-DeadGuards and by the logon Restore task.
  Set-IdleAssertion -On $false
  Unregister-Guard -SessionId $SessionId -Kind $Kind
  Remove-DeadGuards
  if ((Get-GuardCount) -eq 0) {
    Invoke-RestoreState -Baseline (Read-Baseline)
    Clear-Baseline
  }
}
```

- [ ] **Step 6: Run it, expect pass**

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_windows_guard.ps1
```

Expected: `6 tests, 0 failures`.

- [ ] **Step 7: Prove the kill path restores**

Add before `Complete-Tests`:

```powershell
Clear-Content $env:STAYAWAKE_STUB_LOG
$fake = Start-Process powershell -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 60'
Start-Process powershell -WindowStyle Hidden `
  -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$guard,
                '-SessionId','sess-kill','-Kind','turn','-ParentPid',$fake.Id | Out-Null
Start-Sleep -Seconds 3
Stop-Process -Id $fake.Id -Force
Start-Sleep -Seconds 4
$log = Get-Content $env:STAYAWAKE_STUB_LOG -Raw
Assert-Eq -Actual (@([regex]::Matches($log,'restore:')).Count) -Expected 1 `
          -Name 'guard restored after parent was force-killed'
```

Run again. Expected: `7 tests, 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add lib/windows bin/guard.ps1 tests/test_windows_guard.ps1
git commit -m "Add Windows guard loop with restore on every exit path"
```

---

### Task 10: macOS setup and uninstall

**Files:**
- Create: `lib/macos/setup.sh`, `bin/stayawake.sh`

**Interfaces:**
- Consumes: `lib/state.sh`, `lib/macos/platform.sh`.
- Produces: `sa_setup`, `sa_uninstall`, `sa_status`, `sa_restore_if_stale` in `lib/macos/setup.sh`; `bin/stayawake.sh <verb>` dispatching to them.

- [ ] **Step 1: Write `lib/macos/setup.sh`**

```sh
SUDOERS_FILE="/etc/sudoers.d/stayawake"
AGENT_PLIST="$HOME/Library/LaunchAgents/com.stayawake.restore.plist"

# Two exact commands, no wildcard. This grant cannot be used for anything but
# toggling disablesleep on and off.
_sudoers_body() {
  cat <<EOF
%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
EOF
}

_agent_body() { # root
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.stayawake.restore</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>$1/bin/stayawake.sh</string>
    <string>restore-if-stale</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
}

sa_setup() { # root
  tmp=$(mktemp)
  _sudoers_body > "$tmp"
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "stayawake: generated sudoers rule failed validation, refusing to install" >&2
    return 1
  fi
  echo "stayawake needs one administrator approval to allow toggling lid-close sleep."
  sudo install -m 0440 -o root -g wheel "$tmp" "$SUDOERS_FILE" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"

  mkdir -p "$(dirname "$AGENT_PLIST")"
  _agent_body "$1" > "$AGENT_PLIST"
  launchctl unload "$AGENT_PLIST" 2>/dev/null
  launchctl load "$AGENT_PLIST" 2>/dev/null

  echo "stayawake: setup complete. Lid-close coverage is active."
}

sa_uninstall() {
  # Restore first. Uninstalling while a guard is live must never strand a setting.
  sa_restore_if_stale force
  launchctl unload "$AGENT_PLIST" 2>/dev/null
  rm -f "$AGENT_PLIST"
  sudo -n rm -f "$SUDOERS_FILE" 2>/dev/null || sudo rm -f "$SUDOERS_FILE"
  rm -rf "$(state_dir)"
  echo "stayawake: uninstalled. Sudoers rule, login agent, and state removed."
}

# Restores if a baseline exists and no live guard owns it. `force` skips the
# liveness check, for uninstall.
sa_restore_if_stale() { # [force]
  b=$(read_baseline)
  [ -n "$b" ] || return 0
  reap_dead_guards
  if [ "${1:-}" != "force" ] && [ "$(guard_count)" -gt 0 ]; then
    return 0
  fi
  restore_state "$b"
  clear_baseline
  echo "stayawake: restored stale power settings."
}

sa_status() {
  if [ -f "$SUDOERS_FILE" ]; then
    echo "grant:      installed ($SUDOERS_FILE)"
  else
    echo "grant:      NOT installed — run /stayawake setup for lid-close coverage"
  fi
  echo "guards:     $(guard_count) active"
  echo "power:      $(power_source)"
  echo "baseline:   ${$(read_baseline):-none}"
}
```

Note: replace `${$(read_baseline):-none}` — that is not valid sh. Use:

```sh
  b=$(read_baseline)
  [ -n "$b" ] || b=none
  echo "baseline:   $b"
```

- [ ] **Step 2: Write `bin/stayawake.sh`**

```sh
#!/bin/sh
# usage: stayawake.sh <setup|uninstall|status|on|off|restore-if-stale> [session_id]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/lib/state.sh"
. "$ROOT/lib/macos/platform.sh"
. "$ROOT/lib/macos/setup.sh"
. "$ROOT/lib/ancestor.sh"

VERB="${1:-status}"
SESSION="${2:-manual}"

case "$VERB" in
  setup)            sa_setup "$ROOT" ;;
  uninstall)        sa_uninstall ;;
  status)           sa_status ;;
  restore-if-stale) sa_restore_if_stale ;;
  on)
    PARENT=$(find_claude_pid "$$")
    nohup sh "$ROOT/bin/guard.sh" "$SESSION" "pin" "$PARENT" >/dev/null 2>&1 &
    echo "stayawake: pinned on for this session."
    ;;
  off)
    guard_unregister "$SESSION" "pin"
    echo "stayawake: pin released."
    ;;
  *)
    echo "stayawake: unknown verb '$VERB'" >&2
    exit 1
    ;;
esac
```

- [ ] **Step 3: Verify the sudoers rule validates before anything is installed**

```bash
printf '%%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n' > /tmp/sa-test
visudo -cf /tmp/sa-test && echo VALID
```

Expected: `VALID`. This runs on macOS only; on Windows skip and verify in CI. If it does not validate, fix the syntax before proceeding — installing an invalid file into `/etc/sudoers.d/` can lock the user out of `sudo` entirely.

- [ ] **Step 4: Verify `restore-if-stale` is a no-op with no baseline**

```bash
STAYAWAKE_HOME=/tmp/sa-empty sh bin/stayawake.sh restore-if-stale; echo "exit=$?"
```

Expected: no output, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add lib/macos/setup.sh bin/stayawake.sh
git commit -m "Add macOS setup, uninstall, and stale-restore"
```

---

### Task 11: Windows setup and uninstall

**Files:**
- Create: `lib/windows/setup.ps1`, `bin/stayawake.ps1`

**Interfaces:**
- Consumes: `lib/state.ps1`, `lib/windows/platform.ps1`, `lib/ancestor.ps1`.
- Produces: `Invoke-SaSetup -Root`, `Invoke-SaUninstall`, `Invoke-SaStatus`, `Invoke-SaRestoreIfStale [-Force]`.

- [ ] **Step 1: Write `lib/windows/setup.ps1`**

```powershell
# Registers the two elevated scheduled tasks that let the unprivileged guard
# toggle lid-close without a UAC prompt.

function Test-Elevated {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SaSetup {
  param([string]$Root)

  if (-not (Test-Elevated)) {
    Write-Host 'stayawake: relaunching with administrator rights to register the power tasks.'
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',
              (Join-Path $Root 'bin\stayawake.ps1'),'-Verb','setup')
    Start-Process powershell -Verb RunAs -ArgumentList $args -Wait
    return
  }

  # The lid setting carries a hide attribute and does not appear in powercfg
  # output until it is unhidden. Verified on the dev machine, where the whole
  # LIDACTION entry was missing from `powercfg /query SUB_BUTTONS`.
  powercfg /attributes 4f971e89-eebd-4455-a8de-9e59040e7347 `
                       5ca83367-6e45-459f-a27b-476b1d01c936 -ATTRIB_HIDE | Out-Null

  $lid = Get-LidActionLive
  if (-not $lid.Present) {
    Write-Host 'stayawake: this machine exposes no lid-close setting (no lid, or firmware-managed).'
    Write-Host '           Idle-sleep blocking will still work. Lid coverage is unavailable.'
  }

  if (Test-ModernStandbyFromText -Text ((powercfg /a 2>&1 | Out-String))) {
    Write-Host 'stayawake: WARNING — this machine uses Modern Standby (S0 Low Power Idle).'
    Write-Host '           Lid close is partly firmware-controlled and may sleep anyway.'
  }

  $lidScript = Join-Path $Root 'lib\windows\lid.ps1'
  # DontStopIfGoingOnBatteries and AllowStartIfOnBatteries matter: the Task
  # Scheduler default is to refuse to start and to kill running tasks on battery,
  # which would silently disable exactly the case this plugin exists for.
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                                           -DontStopIfGoingOnBatteries `
                                           -ExecutionTimeLimit ([TimeSpan]::Zero)
  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive

  foreach ($action in @('Disable','Restore')) {
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' `
         -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$lidScript`" -Action $action"
    $triggers = @()
    if ($action -eq 'Restore') { $triggers = @(New-ScheduledTaskTrigger -AtLogOn) }
    Register-ScheduledTask -TaskName "StayAwake\$action" -Action $a -Principal $principal `
                           -Settings $settings -Trigger $triggers -Force | Out-Null
  }

  Write-Host 'stayawake: setup complete.'
}

function Invoke-SaUninstall {
  # Restore first. Uninstalling while a guard is live must never strand a setting.
  Invoke-SaRestoreIfStale -Force
  foreach ($t in @('Disable','Restore')) {
    Unregister-ScheduledTask -TaskName "StayAwake\$t" -Confirm:$false -ErrorAction SilentlyContinue
  }
  $d = Get-StateDir
  if (Test-Path $d) { Remove-Item $d -Recurse -Force }
  Write-Host 'stayawake: uninstalled. Scheduled tasks and state removed.'
}

function Invoke-SaRestoreIfStale {
  param([switch]$Force)
  $b = Read-Baseline
  if (-not $b) { return }
  Remove-DeadGuards
  if ((-not $Force) -and ((Get-GuardCount) -gt 0)) { return }
  Invoke-RestoreState -Baseline $b
  Clear-Baseline
  Write-Host 'stayawake: restored stale power settings.'
}

function Invoke-SaStatus {
  $task = Get-ScheduledTask -TaskName 'Disable' -TaskPath '\StayAwake\' -ErrorAction SilentlyContinue
  if ($task) {
    Write-Host 'grant:      installed (StayAwake scheduled tasks)'
  } else {
    Write-Host 'grant:      NOT installed - run /stayawake setup for lid-close coverage'
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
```

- [ ] **Step 2: Write `bin/stayawake.ps1`**

```powershell
param(
  [ValidateSet('setup','uninstall','status','on','off','restore-if-stale')]
  [string]$Verb = 'status',
  [string]$SessionId = 'manual'
)

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\state.ps1')
. (Join-Path $root 'lib\windows\platform.ps1')
. (Join-Path $root 'lib\windows\setup.ps1')
. (Join-Path $root 'lib\ancestor.ps1')

switch ($Verb) {
  'setup'            { Invoke-SaSetup -Root $root }
  'uninstall'        { Invoke-SaUninstall }
  'status'           { Invoke-SaStatus }
  'restore-if-stale' { Invoke-SaRestoreIfStale }
  'on' {
    $parent = Find-ClaudePid -StartPid $PID
    Start-Process powershell -WindowStyle Hidden -ArgumentList `
      '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'bin\guard.ps1'),
      '-SessionId',$SessionId,'-Kind','pin','-ParentPid',$parent | Out-Null
    Write-Host 'stayawake: pinned on for this session.'
  }
  'off' {
    Unregister-Guard -SessionId $SessionId -Kind 'pin'
    Write-Host 'stayawake: pin released.'
  }
}
```

- [ ] **Step 3: Verify status runs without setup and without elevation**

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File bin/stayawake.ps1 -Verb status
```

Expected: prints `grant: NOT installed ...`, a guard count of 0, a power line, and `baseline: none`. No exceptions, exit 0. A status command that throws before setup is the first thing a new user will hit.

- [ ] **Step 4: Run setup on the dev machine and confirm the tasks exist**

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File bin/stayawake.ps1 -Verb setup
powershell -NoProfile -Command "Get-ScheduledTask -TaskPath '\StayAwake\' | Select-Object TaskName,State"
```

Expected: two tasks, `Disable` and `Restore`, both `Ready`. Note that on this specific dev machine `lid: unavailable` is the expected message — it has no lid-close setting.

- [ ] **Step 5: Confirm uninstall is clean**

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File bin/stayawake.ps1 -Verb uninstall
powershell -NoProfile -Command "Get-ScheduledTask -TaskPath '\StayAwake\' -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count"
```

Expected: `0`.

- [ ] **Step 6: Commit**

```bash
git add lib/windows/setup.ps1 bin/stayawake.ps1
git commit -m "Add Windows setup, uninstall, and stale-restore"
```

---

### Task 12: Hook wiring

**Files:**
- Modify: `bin/hook.sh`, `bin/hook.ps1` (replace the Task 1 spike bodies), `hooks/hooks.json`

**Interfaces:**
- Consumes: `bin/guard.sh` / `bin/guard.ps1`, `lib/state.*`, `lib/ancestor.*`.
- Produces: the three wired hook events.

- [ ] **Step 1: Replace `bin/hook.sh`**

```sh
#!/bin/sh
# usage: hook.sh <UserPromptSubmit|Stop|SessionEnd>
# Reads the hook payload on stdin, extracts session_id, and starts or stops a guard.
[ "$(uname -s)" = "Darwin" ] || exit 0
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/lib/state.sh"
. "$ROOT/lib/ancestor.sh"

EVENT="${1:-}"
PAYLOAD=$(cat)
SESSION=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$SESSION" ] || SESSION="unknown"

case "$EVENT" in
  UserPromptSubmit)
    PARENT=$(find_claude_pid "$$")
    nohup sh "$ROOT/bin/guard.sh" "$SESSION" "turn" "$PARENT" >/dev/null 2>&1 &
    ;;
  Stop)
    guard_unregister "$SESSION" "turn"
    ;;
  SessionEnd)
    guard_unregister "$SESSION" "turn"
    guard_unregister "$SESSION" "pin"
    ;;
esac
exit 0
```

- [ ] **Step 2: Replace `bin/hook.ps1`**

```powershell
param([ValidateSet('UserPromptSubmit','Stop','SessionEnd')][string]$Event)

if ($env:OS -ne 'Windows_NT') { exit 0 }

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\state.ps1')
. (Join-Path $root 'lib\ancestor.ps1')

$payload = [Console]::In.ReadToEnd()
$session = 'unknown'
try {
  $obj = $payload | ConvertFrom-Json
  if ($obj.session_id) { $session = [string]$obj.session_id }
} catch {
  # A malformed payload must never block the turn. Fall through with 'unknown'.
}

switch ($Event) {
  'UserPromptSubmit' {
    $parent = Find-ClaudePid -StartPid $PID
    Start-Process powershell -WindowStyle Hidden -ArgumentList `
      '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'bin\guard.ps1'),
      '-SessionId',$session,'-Kind','turn','-ParentPid',$parent | Out-Null
  }
  'Stop' {
    Unregister-Guard -SessionId $session -Kind 'turn'
  }
  'SessionEnd' {
    Unregister-Guard -SessionId $session -Kind 'turn'
    Unregister-Guard -SessionId $session -Kind 'pin'
  }
}
exit 0
```

- [ ] **Step 3: Write the real `hooks/hooks.json`**

Use the dispatch form locked in Task 1's `docs/hook-dispatch.md`. If both forms fire on a platform, the `uname` / `$env:OS` guards at the top of each script make the wrong one a no-op.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/bin/hook.sh\" UserPromptSubmit" },
          { "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"${CLAUDE_PLUGIN_ROOT}/bin/hook.ps1\" -Event UserPromptSubmit" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/bin/hook.sh\" Stop" },
          { "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"${CLAUDE_PLUGIN_ROOT}/bin/hook.ps1\" -Event Stop" }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          { "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/bin/hook.sh\" SessionEnd" },
          { "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"${CLAUDE_PLUGIN_ROOT}/bin/hook.ps1\" -Event SessionEnd" }
        ]
      }
    ]
  }
}
```

- [ ] **Step 4: End-to-end check on the dev machine**

Reinstall the plugin, run `/stayawake setup`, start a session, and submit a prompt that takes a while (`sleep 90` via Bash). During the turn:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File bin/stayawake.ps1 -Verb status
```

Expected: `guards: 1 active` and a non-`none` baseline. After the turn ends, rerun: `guards: 0 active`, `baseline: none`.

- [ ] **Step 5: Confirm hook latency is not felt**

Submit five short prompts in a row. The guard spawns detached, so no perceptible delay should be added at prompt submit. If there is a delay, the hook is blocking on the guard rather than detaching — fix the launch, do not accept the latency.

- [ ] **Step 6: Commit**

```bash
git add bin/hook.sh bin/hook.ps1 hooks/hooks.json
git commit -m "Wire UserPromptSubmit, Stop, and SessionEnd hooks to the guard"
```

---

### Task 13: The `/stayawake` slash command

**Files:**
- Create: `commands/stayawake.md`

**Interfaces:**
- Consumes: `bin/stayawake.sh`, `bin/stayawake.ps1`.

- [ ] **Step 1: Write `commands/stayawake.md`**

```markdown
---
description: Manage stayawake — keeps the machine awake while Claude works
argument-hint: setup | uninstall | status | on | off
---

Run the stayawake CLI with the verb the user supplied: `$ARGUMENTS` (default `status`).

Detect the platform and run exactly one of these from the plugin root:

- macOS / Linux: `sh "${CLAUDE_PLUGIN_ROOT}/bin/stayawake.sh" <verb>`
- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/bin/stayawake.ps1" -Verb <verb>`

Report the command's output to the user verbatim. Do not re-interpret it.

If the verb is `setup`, warn the user first that it will request administrator
or sudo approval once, and say exactly what it grants:

- macOS: a sudoers rule permitting only `pmset -a disablesleep 0` and `pmset -a disablesleep 1`.
- Windows: two scheduled tasks that toggle the lid-close power setting.

If the verb is `on` or `off`, pass the current session id as the second argument
so the pin is scoped to this session.
```

- [ ] **Step 2: Verify each verb from a live session**

Run `/stayawake status`, `/stayawake on`, `/stayawake status`, `/stayawake off`, `/stayawake status`.

Expected: guard count goes 0 → 1 → 0, and the baseline appears and disappears with it.

- [ ] **Step 3: Commit**

```bash
git add commands/stayawake.md
git commit -m "Add /stayawake slash command"
```

---

### Task 14: README, manual test matrix, and publish

**Files:**
- Create: `README.md`
- Modify: `.claude-plugin/plugin.json` (version to `1.0.0`)

- [ ] **Step 1: Write `README.md`**

Sections, in order:

1. **What it does** — one paragraph. Keeps the machine awake while Claude is working; releases the moment the turn ends.
2. **Install**
   ```
   /plugin marketplace add yelloworangebananaa/stayawake
   /plugin install stayawake
   /stayawake setup
   ```
3. **What `setup` grants** — verbatim contents of the sudoers rule, and the two scheduled task definitions. Users are being asked for root; show them exactly what for.
4. **How to remove it by hand** — `sudo rm /etc/sudoers.d/stayawake`, `Unregister-ScheduledTask -TaskPath '\StayAwake\'`, `rm -rf ~/.stayawake`. Never make someone reverse-engineer an uninstall.
5. **Limits** — the two documented exceptions: the 30% battery floor, and Modern Standby machines on Windows.
6. **Config** — `~/.stayawake/config.json`, `{ "batteryFloor": 30 }`.
7. **Manual test matrix** — the table below.

| # | Scenario | Steps | Expected |
|---|---|---|---|
| 1 | Lid close on AC | Plug in, start a 10-minute turn, close the lid for 5 min, open | Turn still running, output continued while closed |
| 2 | Idle on AC | Plug in, start a long turn, do not touch the machine past the idle timeout | Display sleeps, turn keeps running |
| 3 | Lid close on battery above floor | Unplug at >50%, start a long turn, close lid 5 min | Turn still running |
| 4 | Battery crosses the floor | Set `batteryFloor` to just under current charge, run until it crosses | Guard releases, `status` shows 0 guards, settings restored |
| 5 | Terminal killed mid-turn | Start a turn, `kill -9` the Claude process | Within 30s, `status` shows 0 guards and the original setting restored |
| 6 | Hard reboot with a guard live | Start a turn, hold the power button, boot, log in | Login task restores; `status` shows `baseline: none` |
| 7 | Two concurrent sessions | Start turns in two terminals, end one | Setting stays applied until the second ends, then restores once |
| 8 | Uninstall while a guard is live | Start a turn, run `/stayawake uninstall` | Setting restored, grant and state gone |

Scenarios 1–6 must be run on both macOS and Windows before tagging 1.0.0. Record the results in the PR description.

- [ ] **Step 2: Run the full test suite on both platforms**

```bash
sh tests/run.sh
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run.ps1
```

Expected: zero failures on both. CI must be green on `macos-latest` and `windows-latest`.

- [ ] **Step 3: Work the manual matrix**

Do not skip scenarios 5 and 6 — they are the crash-safety guarantee and no unit test covers the real reboot path. If a scenario fails, fix it before publishing; a plugin that strands a power setting is worse than no plugin.

- [ ] **Step 4: Bump the version and commit**

```bash
git add README.md .claude-plugin/plugin.json
git commit -m "Add README with manual test matrix; release 1.0.0"
```

- [ ] **Step 5: Publish**

```bash
gh repo create yelloworangebananaa/stayawake --public --source=. --remote=origin --push
git tag v1.0.0
git push origin v1.0.0
```

Then verify a clean install from the published repo on a machine that has never had it:

```
/plugin marketplace add yelloworangebananaa/stayawake
/plugin install stayawake
/stayawake setup
/stayawake status
```

Expected: installs, sets up with one approval, and reports a sane status.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Protection engages on UserPromptSubmit, releases on Stop | 12 |
| `/stayawake on` pins for the session | 11, 13 |
| Battery floor, default 30, AC always | 8, 9 |
| One-time privileged setup, narrow grant | 10, 11 |
| Idle blocking works without setup | 8, 9 (guard applies the idle assertion regardless of grant) |
| State dir, `original.state`, guard refcount | 5, 6 |
| Atomic first-writer baseline claim | 5, 6 |
| Session-keyed guard files, `-turn` / `-pin` | 5, 6, 12 |
| Battery checked before apply | 8, 9 |
| macOS `caffeinate -i -s -w` | 8 |
| macOS sudoers + LaunchAgent | 10 |
| Windows `SetThreadExecutionState` without display flag | 9 |
| Windows powercfg lid + scheduled tasks | 9, 11 |
| Modern Standby probe and warning | 4, 11 |
| Four restore triggers | 8, 9 (trap/finally, PID poll, guard-file poll), 10, 11 (login task) |
| Idempotent restore | 8, 9 |
| Uninstall restores first | 10, 11 |
| Parser fixture tests | 3, 4 |
| Integration: killed parent, battery crossing, two guards | 5, 6, 8, 9 |
| Manual test matrix in README | 14 |
| Marketplace distribution, MIT | 1, 14 |

No gaps.

**Placeholder scan:** one bug found and fixed inline — Task 10 Step 1 originally contained `${$(read_baseline):-none}`, which is not valid sh; the corrected three-line form is given immediately below it in the task.

**Type consistency:** `read_state` (sh) and `Get-CurrentState` (ps1) both return the baseline string consumed by `restore_state` / `Invoke-RestoreState`. `power_source` returns `"<source> <percent>"` as a string in sh, while `Get-PowerSource` returns an object with `.Source` and `.Percent` in PowerShell — deliberate, idiomatic to each language, and each is consumed only within its own platform. Guard file naming is `<session_id>-<kind>` in both implementations, and both tests assert on the literal name `sess-ac-turn`.

**Known risk carried into execution:** Task 1's hook-dispatch spike is the only step whose outcome could force changes elsewhere. It is first for that reason, and the `uname` / `$env:OS` guards make the dual-registration fallback safe regardless of the answer.
