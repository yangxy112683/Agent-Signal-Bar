# CODEBASE — Agent Signal Bar

> 本文档由 codegraph 初始化生成，描述代码库的实际结构与约定；更新代码后请同步修订，并保持与 `docs/`、README、CHANGELOG 一致。
> 中文为默认协作语言，README/docs 采用中英双语；代码注释以中文为主。

## 这是什么

本地优先（local-first）的 macOS 状态栏 + 桌面悬浮信号灯 App（SwiftUI / AppKit，macOS 14+，Swift 6.0，SPM 构建）。它监控本机 AI Agent（Codex Desktop、Claude Code、本地脚本）的运行状态，用红/黄/绿三色灯持续回答一个问题：**用户现在需不需要介入？**

| Display State | 优先级 | 含义 | 灯效 |
| --- | --- | --- | --- |
| paused | 100 | 监控暂停 | 灰色静止 |
| blocked | 90 | 失败 / 阻塞 / 无法继续 | 红灯快闪 |
| permission | 80 | 等待授权 | 红灯慢闪 |
| needs_review | 70 | 需要查看（attention / notification） | 黄灯慢闪 |
| stale | 60 | 状态过期 / 损坏 / 不可信 | 灰黄慢闪 |
| completed | 55 | 任务完成，去看结果 | 黄灯闪（硬件 `BLINK_YELLOW`） |
| active | 50 | Agent 正在运行 | 绿灯呼吸 |
| ready | 0 | 空闲 | 绿灯常亮 |

聚合优先级即上表顺序：红灯不会被普通工作状态覆盖；`done` / attention 类状态用 30 秒短 TTL 自动回落，避免长期占用。

## 数据流（核心链路）

术语见 [`CONTEXT.md`](CONTEXT.md) / [`GLOSSARY.md`](GLOSSARY.md)。**记录态 ≠ 介入态**：Core 写入状态文件；灯色由 App/CLI 再推导。

```text
事件源（hook / Codex session 日志 / CLI）
        │
        ▼
AgentSignalLightCore 记录态
        SignalStateStore 聚合 + TTL 剪枝
        ~/Library/Application Support/Agent Signal Bar/SignalState/status.json
        │
        ▼
介入态  InterventionDisplay.derive  （= MenuBarStatusModel.displaySnapshot）
        Light Agent 筛选 + 事件回放 fallback + 灯效时段 + 桌面 Presence
        │
        ├─► StatusBarController（菜单栏灯 + 面板/菜单）
        ├─► FloatingSignalWindowController（桌面悬浮灯 + 角标）
        ├─► SignalLightBLEController（蓝牙硬件镜像，可选）
        └─► `agent-signal display --json`（诊断灯色；`status --json` 只是记录态）
```

- **记录态**：`SignalStateStore` 把多 session 事件聚合成文件里的 `aggregate`，按上表优先级取最高，绝不让普通工作事件覆盖红/黄告警。这不是灯。
- **介入态**：`InterventionDisplay`（Core）+ `MenuBarStatusModel.displaySnapshot`（App 包装）。诊断灯色用 `./scripts/agent-signal display --json`。
- **状态文件**：`SignalStateDocument` / `SignalSnapshot`；schema 见 `docs/STATE_SCHEMA.md`，灯语见 `docs/LAMP_LANGUAGE.md`。默认路径是 Application Support，不是 `/tmp/agent-signal`。
- **展示状态语义**：`DisplayState`（8 态）是 v2 展示模型，由原始 `AgentSignal` 映射而来（见 `AgentSignal.swift`）；`LampState` 仅为兼容别名。
- 完成/attention 类会话的**记录态剪枝 TTL** 与**灯效时段**共用同一套可配置时长；灯仍可能从 `recent_events` fallback 显示一条已被剪掉的 session（受灯效时段限制）。

## 模块与产物（Package.swift / codegraph files）

SwiftPM 包 `AgentSignalLight`，平台 macOS 14+。可执行产物 4 个 + 库 2 个：

| Target | 类型 | 职责 |
| --- | --- | --- |
| `AgentSignalLight` | executable（App） | macOS 菜单栏 App：App 生命周期、StatusBar / 悬浮窗 / 设置窗口、Services（监控、用量、更新、BLE 等） |
| `AgentSignalLightCore` | library | 领域核心：信号模型、聚合、状态文件读写、hook 映射、BLE 指令协议、快照 |
| `AgentSignalLightUI` | library | 红绿灯渲染、状态栏图标几何与绘制（`TrafficSignalView`、`StatusBarIconRenderer`） |
| `AgentSignalCLI` | executable | `agent-signal` / `agent-signal-light` CLI（写状态、`status` 记录态、`display` 介入态） |
| `AgentSignalChecks` | executable | `agent-signal-checks`：本机接入自检 |
| `AgentSignalIconPreview` | executable | `agent-signal-icon-preview`：图标/灯效预览 |
| `AgentSignalLightCoreTests` | testTarget | 核心 + 渲染测试（依赖 4 个 target） |

依赖（外部，仅 App target 使用）：Sparkle 2.9.3（自动更新）、SweetCookieKit 0.4.1+（Cookie/凭据导入）。

### 目录导航

- `Sources/AgentSignalLight/` — App 壳。入口 `App/AgentSignalLightApp.swift`（`AgentSignalAppServices` 静态持有 model / updater / statusBarController / BLE controller；单实例守卫 + accessory 激活策略）。子目录：
  - `Services/` — 约 30 个服务：监控（StateFileWatcher、Codex Desktop 系列 scanner、HookInstallManager）、用量（CostUsage 系列、CodexAccountManager、RateLimit、TokenActivity）、UI 控制器（StatusBarController 89 符号、FloatingSignalWindowController 379 符号）、系统（SparkleUpdaterService、LaunchAtLoginManager、GitHubReleaseUpdateChecker、KeychainSecretStore）、BLE（SignalLightBLEController）
  - `Stores/` — `MenuBarStatusModel.swift`（602 符号，App 主状态模型）
  - `Views/` — 菜单栏面板、调试窗口
  - `Support/` — 主题、语言、悬浮窗偏好、调试启动选项
- `Sources/AgentSignalLightCore/` — 领域核心（14 个文件），见上方数据流。
- `Sources/AgentSignalLightUI/` — `TrafficSignalView`（3 个视图组件）、`StatusBarIconRenderer`、`SignalIconGeometry`。
- `Sources/AgentSignalCLI/AgentSignalCLIMain.swift`（78 符号）— CLI 全部子命令。
- `Sources/AgentSignalChecks/AgentSignalChecksMain.swift` — 接入自检。
- `script/` — 开发/发布脚本（build_and_run、doctor、install_hooks.py、package_app/release、verify_* 等）。
- `scripts/` — 运行时 wrapper：`agent-signal`（CLI 入口）、`agent-signal-run`（包装任意命令上报状态）、`codex-signal-hook`、`claude-code-signal-hook`、`generic-agent-signal-hook`。
- `docs/` — 接入与发布文档；`docs/releases/` 为逐版本双语发布说明。
- `Tests/AgentSignalLightCoreTests/` — `AgentSignalLightCoreTests.swift`（332 符号）+ 渲染测试。

## 关键入口（codegraph 实测）

- 状态聚合核心：`SignalStateStore`（AgentSignalLightCore/SignalStateStore.swift）写入记录态；2 处 caller 在 `MenuBarStatusModel.swift`，另有 CLI / checks 调用。
- 灯色 / 介入态：`InterventionDisplay.derive`（Core），App 的 `MenuBarStatusModel.displaySnapshot` 与 CLI `agent-signal display` 共用。
- CLI 子命令写状态：`AgentSignalCLIMain.swift` 调 `SignalStateStore`（`agent-signal <signal> [--session] [--agent] [--event]`，见 `scripts/agent-signal`）。`status` 是记录态，`display` 是灯。
- BLE 指令协议：`SignalLightBLECommand`（GREEN / BLINK_YELLOW / BLINK_RED / OFF）。命令由 `SignalLampAnimation.hardwareCommand` 从软件灯效推导（绿灯闪烁在硬件上变为常亮；完成态默认黄灯闪，硬件写入 `BLINK_YELLOW`），经 `CoreBluetoothSignalLightCommander` 写入。
- App 入口：`AgentSignalLightApp.swift` → `AgentSignalAppServices`（model、sparkleUpdater、statusBarController、signalLightBLEController）。
- 自检入口：`AgentSignalChecksMain.swift`（CLI 用 `--json`）。

## 测试

`Tests/AgentSignalLightCoreTests`（`swift test`）。`script/*.sh` 会优先选用 Xcode 26（`/Applications/Xcode_26*.app` 与 `~/Applications/Xcode-26*.app`），不要把 `DEVELOPER_DIR` 钉死在 `/Applications/Xcode.app`（那台机器上经常是 Swift 5.10）。过滤跑例如：

```bash
swift test --filter testGhostClaudeInstructionsLoadedDoesNotDriveNeedsReviewLight
```

CI：`.github/workflows/ci.yml`。改动聚合或灯色推导时至少让 `AgentSignalLightCoreTests` 与 `agent-signal-checks` 通过。

## 工作流 / 发布

- 日常开发：`./script/build_and_run.sh`；自检 `./script/doctor.sh [--full]`；打包 `./script/package_app.sh --release`；发布 `./script/package_release.sh`（产出 `dist/`：DMG、zip、appcast.xml）。
- Hook 映射（`HookAdapters.swift` / CLI `claude-hook`）改动：先 `./script/install_cli.sh`，再管道冒烟 `echo '{...}' | ./scripts/agent-signal claude-hook`，用 `./scripts/agent-signal display --json` 看灯。只有菜单栏 / 悬浮灯 UI 变了才 `./script/install_app.sh --rebuild`。
- CI：`.github/workflows/ci.yml`（测试）、`release.yml`（发布）。版本号以仓库根 `VERSION` 为准。
- 本地安装 Hook（开发本仓库时用项目级作用域避免与用户级冲突）：`./script/install_hooks.py --target all --codex-scope project --install`。
- 提交信息使用中文（仓库当前风格，见 git log）。

## 代码探索约定（本会话）

- 本仓库位于 `Agent-Signal-Bar/` 子目录（.codegraph 位于外层 `agent-signal-bar/`，二者索引根一致，codegraph 命令在仓库根直接可用；77 files / 4,907 nodes，当前索引已是最新）。
- 优先使用 codegraph（`codegraph explore <query>` / `codegraph node <symbol>` / `query` / `callers` / `callees` / `impact`）定位符号与调用链；codegraph 无结果或需要精确行号时再回退 Grep/Read。
- 索引增量为 daemon 自动 sync（file watcher）；大规模改动后可 `codegraph sync` 手动更新。

## 已知边界（fork 特有）

- 本 fork（origin = yangxy112683/Agent-Signal-Bar）**有意保留上游 v1.5.0 移除的 local-script 信号灯驱动**；合入上游新版本时需重新检查（见记忆 project_fork_divergence）。
- 独立 Sparkle 更新源已配置（独立密钥对 + GitHub Secret），指向本仓库而非上游。
- BLE 灯前缀约定 `coding-`；灯效/布局与上游不同处尽量保持文档同步。
