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
