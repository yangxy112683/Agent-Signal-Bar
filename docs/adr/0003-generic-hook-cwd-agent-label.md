---
status: proposed
---

# Generic hook 在 Swift 层生成带 cwd 的 agent 展示标签

## 背景

当前 CodeBuddy Code CLI 通过本机脚本 `~/.codebuddy/hooks/agent-signal-bar.sh` 接入 Agent Signal Bar。该脚本会在 Python 片段里把原始 agent 名和当前工作目录拼成展示名，例如：

- `codebuddy(agent-signal-bar)`
- `codebuddy(cursor_agent-signal-bar)`

这样可以在悬浮窗和菜单面板的会话列表里区分多个同名 CLI agent，避免都只显示为 `codebuddy`。

但这套逻辑目前只存在于用户本机脚本中，不在 Agent Signal Bar 的 Swift 代码里。因此后续如果 Gemini CLI、其他本地 agent、或任何第三方工具直接走 `generic-agent-signal-hook` / `agent-hook` 接入，就无法复用这套 cwd 项目名展示能力。

## 决策

将 cwd 项目名标签生成逻辑迁移到 `GenericHookAdapter.agentName(payload:environment:)` 中，只覆盖 generic hook 路径，不改 `CodexHookAdapter` 和 `ClaudeHookAdapter`。

Generic hook 解析出的 agent 展示名按以下规则生成：

1. 先按现有逻辑解析基础 agent 名，并记录来源：payload 明确字段、可信嵌套 metadata 字段、环境变量，或 fallback 哨兵值 `agent`。可信嵌套 metadata 字段必须保持受限搜索，不能无条件递归整个 payload，避免把工具入参或用户内容误识别成 agent/source。
2. 如果 payload 中存在 `no_cwd_label: true`，直接返回基础 agent 名，不拼接 cwd 标签。
3. 如果基础 agent 名来自 fallback 哨兵值 `agent`，也直接返回 `agent`，即使 payload 里有 cwd 也不拼接。实现时必须区分“payload 显式传入 `agent: "agent"`”和“没有任何明确 agent 时回退得到的哨兵 `agent`”：前者是调用方显式选择的 agent 名，可以按普通 payload agent 参与 cwd 拼接；后者才是噪声哨兵，不能拼接。这样可以保留 UI 侧 `.localScript` 对 generic hook 噪声的现有保护，避免 `{ "cwd": "/x/demo" }` 被转换成 `agent(demo)` 后误当成真实本地 agent。
4. 否则读取 payload 中的 `cwd`、`workspace`、`workspace_dir`、`project_dir`、`repository`，取路径最后一段作为项目名。cwd 只从 payload 读取，不使用进程当前目录作为替代。
5. 项目名做小写归一化，避免同一项目因 `agent-signal-bar` / `Agent-Signal-Bar` 这类大小写差异显示成两条会话。
6. 如果检测到 Cursor 集成终端环境，则标签前缀加 `cursor_`。
7. 最终返回 `基础agent名(标签)`。

示例：

| payload / environment | 结果 |
| --- | --- |
| `agent=codebuddy`, `cwd=/Users/me/work/agent-signal-bar` | `codebuddy(agent-signal-bar)` |
| `agent=codebuddy`, `cwd=/Users/me/work/Agent-Signal-Bar` | `codebuddy(agent-signal-bar)` |
| `agent=codebuddy`, `cwd=/Users/me/work/agent-signal-bar`, `VSCODE_GIT_ASKPASS_MAIN=/Applications/Cursor.app/...` | `codebuddy(cursor_agent-signal-bar)` |
| `agent=gemini`, `cwd=/Users/me/work/demo` | `gemini(demo)` |
| `agent=gemini`, `cwd=/Users/me/work/demo`, `no_cwd_label=true` | `gemini` |
| 仅 `cwd=/Users/me/work/demo`，没有明确 agent | `agent` |

## Cursor 识别

Cursor 集成终端实测 `TERM_PROGRAM` 为 `vscode`，没有稳定的 Cursor 专属终端变量。当前采用启发式检测：

- `VSCODE_GIT_ASKPASS_MAIN` 路径包含 `Cursor.app`
- 或 `VSCODE_GIT_ASKPASS_NODE` 路径包含 `Cursor`

命中时认为 generic hook 来自 Cursor 集成终端，展示标签使用 `cursor_项目名`。

这是非官方信号，未来 Cursor 或 VS Code 升级后可能失效；失效时退化为普通 `项目名` 标签，而不是阻断 hook 写入。

## CLI `--agent` 语义

`agent-signal agent-hook --agent <name>` 是 CLI 层的显式强覆盖。当前 CLI 入口会优先使用 `parsed.agent`，只有没有传 `--agent` 时才调用 `GenericHookAdapter.agentName(payload:environment:)`。本决策不改变这个语义。

因此，如果 wrapper 这样调用：

```bash
agent-signal agent-hook --agent codebuddy
```

即使 stdin payload 里带有 `cwd`，也不会自动变成 `codebuddy(project)`。如果调用方希望使用 cwd 标签，应把基础 agent 放在 payload 里，或不传 `--agent`，让 generic adapter 处理。

## 不采用 sourceDetail / 新字段的原因

考虑过把 cwd 标签放入展示层的 `sourceDetail` 机制，而不是拼入 agent 字符串。但当前状态文件模型中 `SessionRecord` / `SignalEventRecord` 没有 cwd 字段，展示层只能看到：

- `agent`
- `signal`
- `last_event` / `event`
- `updated_at`
- `quota`

如果使用 `sourceDetail` 展示 cwd 项目名，需要新增 cwd 字段、扩展状态文件 schema、更新读写逻辑、测试和 `docs/STATE_SCHEMA.md`。这会把一个本应很小的 generic hook 展示增强扩大成状态模型变更。

因此本决策接受 agent 字符串同时承担“agent 身份”和“展示标签”的短期取舍，换取更小的实现面和更容易回滚的改动。

## Python hook 过渡策略

本机 `~/.codebuddy/hooks/agent-signal-bar.sh` 目前也有一份 Python 拼接逻辑。Swift 实现落地时，脚本应改成只负责把 CodeBuddy hook 事件映射成 generic hook payload，并透传原始字段：

```json
{
  "event": "PreToolUse",
  "agent": "codebuddy",
  "session_id": "...",
  "cwd": "/Users/me/work/agent-signal-bar"
}
```

在 Swift 逻辑验证通过前，Python 里的旧拼接函数先注释保留，不直接删除，作为临时兜底。验证通过后可移除旧 Python 拼接逻辑。

## 测试要求

需要在 `AgentSignalLightCoreTests` 或 `AgentSignalChecks` 中覆盖：

1. generic hook 对普通 cwd 生成 `agent(project)`。
2. generic hook 对 Cursor 环境生成 `agent(cursor_project)`。
3. 项目名大小写归一化。
4. `no_cwd_label: true` 跳过 cwd 标签。
5. cwd 缺失时保持原始 agent 名，不使用进程当前目录作为替代。
6. 已显式传入 `agent` 时仍默认拼 cwd 标签，除非 `no_cwd_label` 为 true。
7. 无明确 agent、仅有 cwd 时返回 fallback 哨兵值 `agent`，不拼成 `agent(project)`。
8. agent 来自环境变量（如 `AGENT_NAME=gemini`）且 payload 有 cwd 时，生成 `gemini(project)`。
9. payload 显式传入 `agent: "agent"` 且 payload 有 cwd 时，按显式 payload agent 处理，生成 `agent(project)`；只有 fallback 哨兵 `agent` 不拼 cwd。
10. CLI 使用 `--agent` 时保持强覆盖语义，不自动拼 cwd 标签；该约束属于 CLI 层行为，可通过 CLI 测试覆盖，若没有轻量 CLI harness，则作为文档约束保留。

## 已知局限

- 同一个项目内开启多个同名 CLI agent 窗口时，仍无法区分具体窗口，只能区分到项目级别。
- 不同路径但最后一级目录同名时仍会冲突，例如 `/work/a/demo` 与 `/work/b/demo` 都会显示为 `agent(demo)`。
- Cursor 识别依赖启发式环境变量，不是稳定 API。
- agent 字符串被用作展示名，未来若需要按“真实 agent 类型”做筛选，可能需要再引入独立的 display label 字段。

## 影响范围

本决策只影响未显式传 `--agent` 的 `agent-hook` / `generic-hook` / `hook` 命令路径。Codex 和 Claude 仍走各自的专用 adapter，不会因为本决策自动获得 cwd 项目名标签能力。