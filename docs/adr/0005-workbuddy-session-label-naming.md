---
status: accepted
---

# WorkBuddy 会话标签命名策略（Tiered Resolver）

补充 [ADR-0004](./0004-workbuddy-ide-host-generic-hook.md) 的**展示标签选取**规则；不修改 ADR-0003 的 Cursor 段。ADR-0004 中的 `workbuddy_` 前缀已演进为 `workbuddy(标签)` 括号格式（与 Cursor `agent(cursor_项目名)` 并列）。

依据：Wayfinder [#21–#25](https://github.com/yangxy112683/Agent-Signal-Bar/issues/20) 调研与用户偏好 [#22](https://github.com/yangxy112683/Agent-Signal-Bar/issues/22#issuecomment-5451766383)。

## 目标

Playground 会话在菜单栏显示 **`workbuddy(bblock)`**（工程空间 UI 名），而非 `workbuddy(2026-08-28-…)`。

## 标签选取算法（伪代码）

```
function workbuddyAgentName(payload, environment):
  if not isWorkBuddyIDEHost(environment) or isCursorHost:
    return genericCwdLabel(payload, environment)  // ADR-0003

  cwd = payload.cwd
  if env.AGENT_SIGNAL_WORKBUDDY_LABEL:
    return "workbuddy(" + env.AGENT_SIGNAL_WORKBUDDY_LABEL + ")"

  projectID = env.CODEBUDDY_PROJECT_ID
  if projectID and cache[projectID]:
    return "workbuddy(" + cache[projectID] + ")"

  if cwd and not isTimestampPlayground(cwd):
    return "workbuddy(" + lowercase(lastPathComponent(cwd)) + ")"

  return "workbuddy"   // L3：Playground 且无缓存，禁止 timestamp 标签
```

### timestamp Playground 判定

- 父目录名为 `WorkBuddy`（大小写不敏感）
- 末段匹配 `YYYY-MM-DD-HH-MM-SS`、`YYYY-MM-DD` 或 `8–14` 位纯数字目录名

### sessionKey

```
if WorkBuddy host and CODEBUDDY_PROJECT_ID:
  return "workbuddy:" + projectID
else if WorkBuddy host and meaningful cwd:
  return "workbuddy:" + lowercase(lastPathComponent(cwd))
else:
  existing generic session key rules
```

同工程空间多 Playground 会话合并为一行。

## 分支对照

| 场景 | cwd | project_id | 缓存 | agentName | sessionKey |
|------|-----|------------|------|-----------|------------|
| Teams Playground | timestamp | 有 | `bblock` | `workbuddy(bblock)` | `workbuddy:p_4a72…` |
| Playground 首跑 | timestamp | 有 | 无 | `workbuddy` | `workbuddy:p_4a72…` |
| 本地目录 | `~/work/foo` | 无 | — | `workbuddy(foo)` | `workbuddy:foo` |
| 本地目录 + Teams | `~/work/foo` | 有 | `bblock` | `workbuddy(bblock)` | `workbuddy:p_4a72…` |

## 降级路径（L1 → L3）

1. **L1**：`CODEBUDDY_PROJECT_ID` + `workbuddy-project-names.json` 缓存
2. **L2**：非 timestamp 的 `cwd.lastPathComponent`（小写）
3. **L3**：裸 `workbuddy`（无括号标签）

禁止：将 timestamp 目录名作为首选标签。

## 缓存文件

路径：`$AGENT_SIGNAL_LIGHT_STATE_DIR/workbuddy-project-names.json`（默认 `/tmp/agent-signal/`）

```json
{
  "version": 1,
  "projects": {
    "p_4a72e62b48154560a5ce37551dbb4a9b": { "displayName": "bblock" }
  }
}
```

v2（未实现）：菜单栏 App 调 `wb:workspaces:getDisplayNames` 自动刷新。

## 环境变量

| 变量 | 用途 |
|------|------|
| `CODEBUDDY_PROJECT_ID` | hook 子进程注入；L1 查找键 |
| `AGENT_SIGNAL_WORKBUDDY_LABEL` | 单会话强制标签（测试/高级用户） |

## 明确不做

- hook 热路径调 git / 网络 / 解析 Bash `cd`
- 使用 `sessions.title` 作工程空间名
- 修改 WorkBuddy 上游 payload

## 实现位置

- `WorkBuddyProjectNameCache` — 读缓存 JSON
- `GenericHookAdapter.agentName` / `sessionKey` — Tiered Resolver
