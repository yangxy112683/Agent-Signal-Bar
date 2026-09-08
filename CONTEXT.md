# Agent Signal Bar

本地优先的 macOS 信号灯应用：监控本机 AI Agent（Codex、Claude Code、本地脚本等）的运行状态，用红/黄/绿信号灯回答一个问题——用户现在需不需要介入。中文为默认协作语言。

## Language

**介入态（Intervention State）**:
“用户现在需不需要介入”的当前答案。由已记录的 session/事件、Agent 筛选、桌面 Presence、暂停状态与当前时间共同推导；随时间推进而改变。菜单栏、悬浮窗与 BLE 硬件灯都消费同一个介入态。注意与 `DisplayState` 区分。
_Avoid_: 灯状态、可见状态、当前状态

**灯状态（Display State）**:
灯效模型中的八个状态：`ready`、`active`、`completed`、`needs_review`、`permission`、`blocked`、`stale`、`paused`。它对应灯的具体表现（颜色、闪烁、呼吸），不随时间自动变化。
_Avoid_: 介入态、灯语状态

**记录态（Recorded Signal State）**:
状态文件（status.json）中持久化的内容：session 记录、最近事件与 aggregate。它记录事实，不包含 Agent 筛选、桌面 Presence、调试覆盖等本地展示选择。
_Avoid_: 当前状态、聚合状态

**聚合信号（Aggregate Signal）**:
状态文件中的 `aggregate` 字段，仅作为没有任何活跃 session 时的回退来源；新 session 写入后由 session 重新计算。它不等于介入态。
_Avoid_: 当前信号、灯语

**灯效 Agent 筛选（Light Agent Scope）**:
用户选择的、允许驱动信号灯的 Agent 来源集合（Codex 各入口、Claude、local-script）。介入态推导时先按此筛选 session 与事件。
_Avoid_: 过滤器、Agent 范围选项

**桌面 Presence（Desktop Presence）**:
本机正在运行的 Agent 桌面应用/终端进程探测结果（`desktop-app:` / `platform-presence:` session）。它只能补充或按规则替代过期的工作 session，不能覆盖红灯/黄灯告警。
_Avoid_: 桌面会话、进程探测

**告警（Alert）**:
`permission` 与 `blocked`（红灯，需马上处理）以及 `needs_review`（黄灯，有空看一眼）。红灯/黄灯即表示用户需要介入，任何正常工作情况都不得覆盖告警。
_Avoid_: 警告、红黄状态

**灯效时段（Display Window）**:
某个 session/事件在介入态推导中可见的时长（如 completed 与 attention 类的展示窗口）。不同展示时段有各自命名与语义；completed/attention 类与记录态的剪枝 TTL 共用同一套可配置时长，不许硬编码。
_Avoid_: TTL、过期时间、窗口期
