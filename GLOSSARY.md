# Glossary

Canonical terms live in [`CONTEXT.md`](CONTEXT.md). Read that first.

## Lamp color debugging

1. **记录态 ≠ 介入态.** `status.json` / `agent-signal status --json` is recorded store state. The menu bar, floating lamp, and BLE consume **介入态**, then the same lamp effects. BLE has no separate color table.
2. Dump the lamp: `./scripts/agent-signal display --json`
3. Derivation is `Sources/AgentSignalLightCore/InterventionDisplay.swift` — the same pipeline as `MenuBarStatusModel.displaySnapshot` (Light Agent scopes, recent-event fallback, display windows).
4. **CLI 介入态 ≠ 正在跑的 App。** `display --json` 读这个 shell 的状态路径。GUI 读的是进程环境。Cursor agent 里 `export AGENT_SIGNAL_LIGHT_STATE_FILE` 会留到后续 `install_app.sh --rebuild`，GUI 就会盯着一份空的临时 `status.json`，hook 仍写默认 SignalState。`./script/doctor.sh` 会 fail。核对：`ps eww -p "$(pgrep -x AgentSignalLight)"`.

Do not diagnose a yellow lamp from `status --json` sessions/aggregate alone.
