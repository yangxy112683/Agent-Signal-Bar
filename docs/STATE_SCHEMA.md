# State Schema

Agent Signal Bar 默认读取和写入：

```text
~/Library/Application Support/Agent Signal Bar/SignalState/status.json
```

默认目录是每个 macOS 用户各自的 Application Support 目录，不会读取、回退到或自动迁移旧的全局
`/tmp/agent-signal`。默认目录权限为 `0700`，`status.json`、原子写入临时文件和 `state.lock`
均为 `0600`；符号链接、非普通文件、错误所有者和多硬链接叶子文件会被拒绝。锁不可用时也不会绕过锁读取磁盘，
调用方会收到 `stale` 状态。

当前 schema 版本是 `1`。缺失 `events` 或 `schema_version` 的旧文件仍可读取；新写出的文件会补齐这些字段。

所有 `updated_at` 时间戳以**北京时间**（`Asia/Shanghai`，`+08:00` 偏移）写出，例如 `2026-05-28T11:45:00+08:00`。这只改变可读呈现，不改变所代表的绝对时刻，因此 TTL 计算与状态聚合不受影响。读取端同时兼容历史的 UTC `Z` 格式（如 `2026-05-28T03:45:00Z`），两者解析为同一时刻。

## Document

```json
{
  "schema_version": 1,
  "aggregate": "working",
  "updated_at": "2026-05-28T11:45:00+08:00",
  "sessions": {
    "codex-main": {
      "agent": "codex",
      "signal": "working",
      "last_event": "PreToolUse",
      "updated_at": "2026-05-28T11:45:00+08:00"
    }
  },
  "events": [
    {
      "id": "D4204E0A-5B5D-4DFB-A3BC-643E6C7C6F8F",
      "session_id": "codex-main",
      "agent": "codex",
      "signal": "working",
      "event": "PreToolUse",
      "updated_at": "2026-05-28T11:45:00+08:00"
    }
  ]
}
```

## Fields

| Field | Required | Meaning |
| --- | --- | --- |
| `schema_version` | yes | Schema version. Current value is `1`. |
| `aggregate` | yes | Current aggregate signal shown by the menu bar. |
| `updated_at` | yes | ISO-8601 document update time (Beijing time, `+08:00`). |
| `sessions` | yes | Map of session id to latest session state. |
| `events` | yes | Recent event history, newest displayed first by the app. |

Session fields:

| Field | Required | Meaning |
| --- | --- | --- |
| `agent` | no | Agent source, such as `codex`, `claude-code`, `local-script`, or `script`. |
| `signal` | yes | One of the supported signal names. |
| `last_event` | no | Last source event that produced the signal. |
| `updated_at` | yes | ISO-8601 session update time (Beijing time, `+08:00`). |

Bare CLI signal commands that do not pass `--session` are stored as session id `manual` with agent `manual` and event `ManualSet`. This keeps manual testing and menu buttons inside the same aggregation model as Codex, Claude Code, and local scripts. Manual `idle` / `reset` clears sessions instead of leaving a stale manual session behind.

Event fields:

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Event UUID. |
| `session_id` | yes | Session that produced the event. |
| `agent` | no | Agent source. |
| `signal` | yes | Signal written by the event. |
| `event` | no | Source event name. |
| `updated_at` | yes | ISO-8601 event time (Beijing time, `+08:00`). |

## Environment

```bash
export AGENT_SIGNAL_LIGHT_STATE_FILE=/path/to/status.json
export AGENT_SIGNAL_LIGHT_STATE_DIR="$HOME/Library/Application Support/Agent Signal Bar/SignalState"
export AGENT_SIGNAL_LIGHT_EVENT_LIMIT=50
export AGENT_SIGNAL_LIGHT_COMPLETED_TTL_SECONDS=90
export AGENT_SIGNAL_LIGHT_ATTENTION_TTL_SECONDS=30
export SIGNAL_LIGHT_SESSION_TTL_SECONDS=1800
```

状态位置覆盖优先级是 `AGENT_SIGNAL_LIGHT_STATE_FILE`、`AGENT_SIGNAL_LIGHT_STATE_DIR`、
`SIGNAL_LIGHT_STATE_DIR`、默认 Application Support 目录。显式覆盖表示调用者信任该目录；已存在的覆盖目录
必须由当前用户拥有、不是符号链接、不能允许组或其他用户写入，且不能携带扩展 ACL。新建覆盖目录使用 `0700`，状态和锁文件使用 `0600` 并清除扩展 ACL。默认专用目录也会通过文件描述符加固为 `0700` 且清除扩展 ACL；状态读取使用 `O_NOFOLLOW` 打开后的同一文件描述符，避免路径校验与读取之间的替换窗口。
登录项的 `app.out.log` / `app.err.log` 同样必须是当前用户拥有的单链接普通文件；安装前会以 `O_NOFOLLOW` 创建或打开、清除 ACL 并收紧为 `0600`。

If the JSON is missing, the app falls back to `ready` / `idle`. If the JSON is damaged or cannot be decoded, the app shows `stale` so the menu bar does not imply a trustworthy idle state. Unknown signal names are not accepted by the CLI.

`aggregate` is a fallback when there are no active sessions. A stale or paused aggregate does not lock the state forever; once a new non-paused session is written, the aggregate is recomputed from sessions.

Completed sessions use a shorter TTL than normal sessions. By default `done` stays visible for 30 seconds, then the runtime prunes that completed session and returns to `idle` / `ready` instead of `stale`. Snapshot reads persist TTL pruning back into the JSON so direct file readers, the CLI, and the menu bar converge on the same aggregate. When pruning changes the aggregate, `updated_at` is refreshed to the prune time so the menu and CLI do not show the old event time as the current status update time.

The menu bar and floating-light display windows (the「灯效时段」) for completed and attention-class sessions are the same configurable durations as the pruning TTLs above (`AGENT_SIGNAL_LIGHT_COMPLETED_TTL_SECONDS` / `AGENT_SIGNAL_LIGHT_ATTENTION_TTL_SECONDS`). The app reads both from the same store instance, so a `done` session pruned after N seconds also stops being shown by the lights after N seconds — no separate hard-coded window may disagree with the pruning TTL.

Attention-class sessions (`needs_review` / `permission` / `blocked`) use their own TTL (`AGENT_SIGNAL_LIGHT_ATTENTION_TTL_SECONDS`, default 30 seconds), matching the completed-session linger. The menu-bar fallback window for these alerts is the same configurable duration, so a pruned session cannot be resurrected from recent-event history for minutes. These states are protected against normal working/done events, so a session left behind by an agent that has already exited (for example a stray `--agent <name>` attention event) would otherwise linger for the full 30-minute session TTL. The shorter attention TTL lets such zombie sessions expire to `stale` on their own; `agent-signal reset` still clears them immediately.

## CLI Status Output

`agent-signal status --json` prints a machine-readable snapshot of **recorded** state (the store aggregate after TTL pruning). Commands that update state, such as `agent-signal working --session job --json`, can also use the same output format.

This is not the lamp. The floating light and menu bar apply Light Agent scopes, recent-event fallback sessions, and display windows on top of the recorded snapshot. Use `agent-signal display --json` for that derived view.

`display_state` in `status --json` is the recorded aggregate's v2 state: `ready`, `active`, `completed`, `needs_review`, `permission`, `blocked`, `stale`, or `paused`. `lamp_state` is kept for compatibility and currently has the same value.

```json
{
  "schema_version": 1,
  "aggregate": "working",
  "display_state": "active",
  "lamp_state": "active",
  "priority": 50,
  "display_name": "工作中",
  "summary": "Agent 正在读写文件、跑工具或测试。",
  "action": "不用处理",
  "state_file": "/Users/example/Library/Application Support/Agent Signal Bar/SignalState/status.json",
  "updated_at": "2026-05-28T03:45:00Z",
  "sessions": [
    {
      "session_id": "codex-main",
      "agent": "codex",
      "signal": "working",
      "last_event": "PreToolUse",
      "updated_at": "2026-05-28T11:45:00+08:00"
    }
  ],
  "recent_events": [
    {
      "id": "D4204E0A-5B5D-4DFB-A3BC-643E6C7C6F8F",
      "session_id": "codex-main",
      "agent": "codex",
      "signal": "working",
      "event": "PreToolUse",
      "updated_at": "2026-05-28T11:45:00+08:00"
    }
  ]
}
```

## CLI Display Output

`agent-signal display --json` prints the same derivation as `MenuBarStatusModel.displaySnapshot`: Light Agent scopes, recent-event fallback sessions, display-window TTLs, and the final lamp `display_state`.

It reads Light Agent preferences from `UserDefaults` suite `com.agentsignallight.AgentSignalLight`. Override with `--scopes codex-cli,claude-code,local-script` and `--selection-mode manual|following`. Desktop presence is omitted (`presence_included: false`); pause overlay is also omitted (it is in-memory in the app).

`recorded_display_state` is the store aggregate. `display_state` is the lamp. `exclusions` lists attention-class / completed events and stored sessions that did not become display sessions, with reasons such as `attention_window_expired`.

```json
{
  "schema_version": 1,
  "recorded_display_state": "active",
  "display_state": "active",
  "selection_mode": "manual",
  "scopes": ["codex-cli", "claude-code", "local-script"],
  "display_scopes": ["codex-cli", "claude-code", "local-script"],
  "presence_included": false,
  "fallback_sessions": [],
  "exclusions": [
    {
      "session_id": "claude-ghost",
      "agent": "claude-code",
      "event": "InstructionsLoaded",
      "signal": "attention",
      "reason": "attention_window_expired"
    }
  ]
}
```
