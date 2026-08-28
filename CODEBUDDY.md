# CODEBUDDY.md

This file provides guidance to CodeBuddy Code when working with code in this repository.

> 注意：仓库根目录是 `agent-signal-bar/`，但所有代码都位于 `Agent-Signal-Bar/` 子目录中。下面所有命令都在 `Agent-Signal-Bar/` 目录下执行。

## 项目概述

Agent Signal Bar 是一个 macOS 14+ 的 Swift 6.0 应用（Swift Package Manager，无 Xcode 工程文件）。它在菜单栏和桌面浮窗上用红/黄/绿三色信号灯展示本地 AI agent（Codex、Claude Code、本地脚本）的实时状态：空闲、思考、工作、完成、等待授权、阻塞等。本地优先，不依赖云服务，所有状态写入本地 JSON 文件。

## 常用命令

```bash
swift test                                  # 运行全部测试（XCTest）
swift test --filter testFloatingSignalGeometryTracksLayout   # 运行单个测试
swift build --product agent-signal          # 构建 CLI
swift build --product AgentSignalLight       # 构建 app 二进制

./script/build_and_run.sh                   # 打包 .app 并启动（开发主流程）
./script/build_and_run.sh --verify          # 启动后验证进程存活
./script/build_and_run.sh --ui-verify       # 启动并验证调试窗口
./script/build_and_run.sh --status-item-verify   # 验证菜单栏 status item 健康
./script/build_and_run.sh --logs            # 启动并流式查看日志

./script/doctor.sh                          # 本地诊断
./script/verify_local_integrations.sh       # 端到端验证 hook/CLI 集成（CI 也跑这个）

swift run agent-signal-checks               # 运行内置断言检查（聚合优先级、映射、schema 等）

./script/package_app.sh --release           # 打包 release .app（默认 debug）
./script/package_dmg.sh                     # 编译 release 并打包成可分发的 DMG（dist/AgentSignalBar.dmg）
./script/package_release.sh                 # 生成本地 zip + DMG + appcast.xml
```

CI（`.github/workflows/ci.yml`）执行顺序：`bash -n` 检查所有 shell 脚本 → `swift test` → 构建四个 product → `verify_local_integrations.sh`。修改 shell 脚本后务必本地跑 `bash -n` 验证语法。

### 工具链选择（重要，打包前必读）

打包脚本（`package_app.sh` / `package_dmg.sh` / `package_release.sh`）默认**优先使用 `/Applications/Xcode.app` 的工具链**。但本机 Xcode 可能自带过旧的 Swift（例如 Xcode 15.3 是 Swift 5.10），低于 `Package.swift` 要求的 6.0，会直接报错 `using Swift tools version 6.0.0 but the installed version is 5.10.0`。

解决办法：确认哪套工具链是 Swift 6.0+（`swift --version` vs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift --version`），打包时显式指向那一套。例如本机命令行工具链是 6.1.2 时：

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools ./script/package_dmg.sh
```

脚本内的 `swift_tool` 逻辑：已设置 `DEVELOPER_DIR` 时用它，否则才回退到 Xcode.app。所以显式设置 `DEVELOPER_DIR` 即可绕过默认选择。纯 `swift build` / `swift test` 一般直接用命令行工具链即可，不受此影响。

无代码签名身份时打包脚本走 ad-hoc 签名，本地运行没问题，但未公证；首次打开如被 Gatekeeper 拦截，右键 app → 打开，或在「系统设置 → 隐私与安全性」点「仍要打开」。

## 代码架构

四个 SPM target，依赖方向是单向的（Core 不依赖任何上层）：

```
AgentSignalLightCore   ← 状态模型、信号枚举、聚合逻辑、hook 适配、状态文件读写（纯逻辑，可测试，无 UI）
AgentSignalLightUI     ← 依赖 Core：信号灯渲染、图标几何、动画
AgentSignalLight       ← 依赖 Core + UI + Sparkle：macOS app 本体（菜单栏、浮窗、设置窗口、各种监控 Service）
AgentSignalCLI         ← 依赖 Core：agent-signal CLI
AgentSignalChecks      ← 依赖 Core：可执行的断言检查（非 XCTest），用作快速回归
AgentSignalIconPreview ← 依赖 Core + UI：图标预览工具
```

### 信号系统（理解这个是理解整个项目的关键）

两层枚举，定义在 `Sources/AgentSignalLightCore/AgentSignal.swift`：

- **`AgentSignal`**：细粒度的原始信号（`thinking`、`working`、`tool_done`、`permission_request`、`blocked`、`max_tokens` 等 20+ 种）。`AgentSignal.normalized(_:)` 把外部 hook 传入的各种写法（`PreToolUse`、`tool-use`、`failed` 等）归一化成枚举。
- **`DisplayState`**：粗粒度的展示状态（`ready` / `active` / `completed` / `needsReview` / `permission` / `blocked` / `stale` / `paused`），每个有 `priority` 数值。多个 agent/session 同时活跃时，按 priority 取最高优先级展示。

聚合优先级（高 → 低）：`paused > blocked > permission > needs_review > stale > active > completed > ready`。核心设计：**红色状态（blocked/permission）永远不会被正常的工作状态覆盖**，黄色 attention 状态也受保护。

### 状态存储

`Sources/AgentSignalLightCore/SignalStateStore.swift` 是状态读写的中心：

- 默认状态文件：`/tmp/agent-signal/status.json`（可用环境变量覆盖，见下）。
- 用 `flock`（`state.lock`）做进程间文件锁，写入用 atomic write。
- 维护多个 session 的状态字典 + 最近事件历史（默认上限 50 条，会去重）。
- TTL 机制：普通 session 默认 30 分钟过期，`done`/`tool_done` 等完成态默认 30 秒后回到 idle。过期的非完成态会被标记为 `stale`。
- 处理乱序事件、completed session 的重放抑制等边界逻辑——改动这个文件时要特别小心，相关断言都在 `AgentSignalChecks` 里。

相关环境变量：`AGENT_SIGNAL_LIGHT_STATE_FILE`、`AGENT_SIGNAL_LIGHT_STATE_DIR`、`AGENT_SIGNAL_LIGHT_EVENT_LIMIT`、`AGENT_SIGNAL_LIGHT_COMPLETED_TTL_SECONDS`、`SIGNAL_LIGHT_SESSION_TTL_SECONDS`。

### Hook 适配

`Sources/AgentSignalLightCore/HookAdapters.swift` 包含 `CodexHookAdapter` / `ClaudeHookAdapter` / `GenericHookAdapter`，把不同 agent 的 JSON 事件载荷映射成 `AgentSignal` 并推断 session/agent 名。CLI（`AgentSignalCLIMain.swift`）的 `codex-hook` / `claude-hook` / `agent-hook` 子命令从 stdin 读 JSON 调用这些适配器。`scripts/` 下的 shell 包装器（`codex-signal-hook` 等）最终都调到 CLI。

Codex Desktop 还有一条不依赖 hook 的路径：app 内的 `CodexDesktopActivityMonitor` 等 Service 直接读本地 Codex session 日志（`CodexDesktopSessionParser` 解析），所以即使不装 hook 也能监控 Codex Desktop。

### app 层（AgentSignalLight）

- 入口 `App/AgentSignalLightApp.swift`：纯菜单栏 app（`.accessory` 激活策略，无 Dock 图标），有单实例守卫，集成 Sparkle 自动更新。
- `Services/`：各种监控器（Codex 日志活动、配额、token、工具调用）、`StateFileWatcher`（监听状态文件变化）、`StatusBarController`（菜单栏 status item）、`FloatingSignalWindowController`（桌面浮窗）、`HookInstallManager`、`SparkleUpdaterService` 等。
- `Stores/MenuBarStatusModel.swift`：UI 的可观察状态模型。
- `Support/`：语言、主题、浮窗偏好、调试启动选项。
- `Views/`：菜单栏面板、调试窗口（SwiftUI）。

## 约定与注意事项

- 面向用户的字符串普遍是中英双语（app 内通过 `model.text("中文", "English")`），用户可见的状态描述/摘要直接写在 `AgentSignal` 的 `displayName` / `summary` / `humanAction` 里。
- 版本号在 `VERSION` 文件（`VERSION=x.y.z` + `BUILD=n`），不要手改散落各处。
- 发布说明放在 `docs/releases/vX.Y.Z.md`（中英双语，结构见 `CHANGELOG.md` 末尾的 "Release Note Standard"），`CHANGELOG.md` 只维护索引表格。
- `.codex/hooks.json` 是机器本地文件，已被 gitignore，不要提交。
- 改了核心聚合/状态逻辑后，跑 `swift run agent-signal-checks` 比单跑 `swift test` 更能覆盖状态机边界。

## 相关文档

`docs/` 下有：`STATE_SCHEMA.md`（状态文件 schema）、`LAMP_LANGUAGE.md`（信号灯语言）、`CODEX_SETUP.md`、`CLAUDE_CODE_SETUP.md`、`LOCAL_SCRIPT_SETUP.md`、`GITHUB_RELEASES.md`、`RELEASE_CHECKLIST.md`。

## Agent skills

### Issue tracker

Issues 跟踪在 GitHub Issues（fork 仓库 `yangxy112683/Agent-Signal-Bar`，`gh` 默认仓库已指向它；origin 仍指上游 `guan-ops`）；外部 PR 不作为 triage 渠道。详见 `docs/agents/issue-tracker.md`。

### Triage labels

使用默认五标签词表：`needs-triage` / `needs-info` / `ready-for-agent` / `ready-for-human` / `wontfix`。详见 `docs/agents/triage-labels.md`。

### Domain docs

单一上下文布局（根目录 `CONTEXT.md` + `docs/adr/`）。详见 `docs/agents/domain.md`。
