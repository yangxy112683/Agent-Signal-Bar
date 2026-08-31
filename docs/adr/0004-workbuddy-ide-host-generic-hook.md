---
status: accepted
---

# WorkBuddy 作为 IDE Host：generic hook 展示名 `workbuddy(标签)`

> **标签命名策略**见 [ADR-0005](./0005-workbuddy-session-label-naming.md)（Tiered Resolver、`project_id` 缓存）。本文保留宿主检测与 hook 安装约定。

Generic hook 的 cwd 展示名在 WorkBuddy 宿主下格式为 `workbuddy(标签)`；非 Playground 时标签取自 cwd 末段（ADR-0003），Playground 时优先 `CODEBUDDY_PROJECT_ID` 缓存（ADR-0005）。WorkBuddy（仅 `WorkBuddy.app`）是第二个 IDE Host，不是新的 Agent 源。与 Cursor 的 `cursor_` 前缀并列。标签只在 Swift `GenericHookAdapter` 里拼；不修订 ADR-0003 的 Cursor 段。

放弃把本文写进 ADR-0003：cwd 迁移和「多宿主检测」会绑在同一份决策里。放弃套 Cursor 的 `VSCODE_GIT_ASKPASS_*` 启发式：WorkBuddy 不是 VS Code 壳，活进程上没有这些键，照抄不会命中。放弃让调用方手改 `~/.workbuddy`：WorkBuddy 托管 CLI 读该目录，本机 `~/.codebuddy` 里的 hook 默认走不到；注册由 Agent Signal Bar 自动写入，对齐现有 Claude / Codex 的 hook 安装。

## 认定

环境大小写不敏感。下列任一成立即认定 WorkBuddy，不要求同时成立：

- `WORKBUDDY_APP_NAME` 或 `WORKBUDDY_APPLICATION_NAME` 等于 `WorkBuddy`
- 或 `WORKBUDDY_APP_PATH` / `WORKBUDDY_RESOURCES_PATH` 含 `WorkBuddy.app`

不把 `CODEBUDDY_*` 当主信号。不用子串 `buddy`（会误伤 `CodeBuddy.app`）。`CodeBuddy.app` 与 `CodeBuddy CN.app` 不是 WorkBuddy。

该宿主里发出的所有 generic hook 都加前缀，不限 `codebuddy`。

## 降级与互斥

未命中则返回 `workbuddy`（无标签）或 `workbuddy(标签)`，见 ADR-0005。不阻断 hook 写入。

检测器按键族分开。若 Cursor askpass 与 WorkBuddy 信号同时为真：先 Cursor，再 WorkBuddy；最多一个前缀；`cursor_` 赢。互斥写在本文，不改 ADR-0003。

## Hook 约定与安装

Agent Signal Bar 自动把 generic hook 写入 WorkBuddy 托管 CLI 的 `~/.workbuddy` 配置。用户和调用方不手改文件。

hook 进程必须透传原始 `agent`、`cwd`，保留环境变量，禁止预拼接宿主前缀。CLI `--agent` 强覆盖语义仍按 ADR-0003。

## 本决策不包含

- 实现 Swift 检测、测试或 hook 安装器（另开会话）
- 改 `~/.codebuddy/hooks` 或手工改 `~/.workbuddy`
- 给 `CodeBuddy.app` / `CodeBuddy CN.app` 加宿主前缀
- 把 WorkBuddy 自己的 Agent 做成 Codex Desktop 那种读会话日志
- 修订 ADR-0003 的 Cursor 识别段
