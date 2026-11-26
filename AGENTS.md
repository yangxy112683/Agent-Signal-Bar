# Agent notes

Swift build / test: `source script/lib/developer_dir.sh` first. Bare `swift build` picks Swift 5.10 and fails dependency resolution.

Lamp or menu-bar color bugs:

1. Read [`CONTEXT.md`](CONTEXT.md) / [`GLOSSARY.md`](GLOSSARY.md) (记录态 ≠ 介入态).
2. Dump `./scripts/agent-signal display --json`. Do not trust `status --json` for lamp color.
3. Code: `InterventionDisplay` then `MenuBarStatusModel.displaySnapshot`.
4. `./script/doctor.sh` fails if the running/installed app GitCommit ≠ `HEAD`, or the running process is bound to `AGENT_SIGNAL_LIGHT_STATE_FILE` instead of the default SignalState path. 灯色以该进程实际读取的状态文件为准. Doctor checks `/Applications/AgentSignalLight.app` when it exists, while `install_app.sh` installs to `~/Applications`; a leftover copy in `/Applications` fails this check.

Hook mapping (`HookAdapters.swift`, CLI `claude-hook` / `codex-hook`) smoke with `./script/install_cli.sh` and a piped hook payload. `scripts/claude-code-signal-hook` drops payloads that have no `transcript_path` and a non-PascalCase event name (Cursor guard), so Claude test payloads carry `transcript_path`. CI runs `script/test_*.py` but not doctor: put hook regression cases in `script/test_claude_code_signal_hook.py`.

Run `./script/install_app.sh --rebuild` only when menu bar / floating lamp UI changed, and commit first: the app stamps `HEAD` at build time, so a pre-commit rebuild makes doctor report GitCommit ≠ HEAD.
