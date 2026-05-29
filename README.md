# Agent Signal Bar

中文名可以叫 Agent 红绿灯状态栏、智能体状态灯，或者 AI 运行信号灯。

这是一个常驻 macOS 菜单栏的小组件，用三颗红黄绿状态灯快速表达 Codex、Claude Code 或本地脚本的运行状态。它保留了参考项目 `starlight36/vibecoding-signal-light` 的灯语、hook 映射和 session 聚合逻辑，但去掉实体 GPIO 硬件，专注状态栏体验。

## 灯语

| Agent 状态 | Display State | 状态栏表现 | 用户含义 |
| --- | --- | --- | --- |
| Idle / 空闲 | `ready` | 绿色常亮 | 没事，不用管 |
| Thinking / 思考中 | `active` | 绿色亮度+大小呼吸 | Agent 正在理解任务 |
| Working / 执行中 | `active` | 绿色亮度+大小呼吸 | 正在改文件、跑命令、调用工具 |
| Done / 完成 | `completed` | 绿色短闪 | 任务完成 |
| Attention / 需要查看 | `needs_review` | 黄灯慢闪 | 有空看一下 |
| Permission / 等待授权 | `permission` | 红灯慢闪 | 需要马上批准 |
| Blocked / 失败或阻塞 | `blocked` | 红灯快闪 | 需要马上处理 |
| Stale / 状态不可信 | `stale` | 灰黄慢闪 | 需要确认状态 |
| Off / 手动关闭 | `paused` | 灰色静止 | 暂停显示 |

内部 signal 名称仍保留为 `idle`、`thinking`、`working`、`tool_done`、`attention`、`done`、`permission`、`blocked`、`off` 等。v2 新增展示层 display state，用来回答“用户现在需不需要介入”：绿色表示正常，黄色表示需要注意，红色表示必须处理，灰色表示暂停或状态不可信。

多 session 聚合优先级：

```text
paused > blocked > permission > needs_review > stale > active > completed > ready
```

当前灯效会持续表达当前状态，直到新的事件更新状态文件；`completed/done` 是例外，它默认停留 8 秒后自动回到 `ready/idle`，避免完成态长期占着状态栏。Codex / Claude Code 的普通 `Stop` 会映射成 `done`，紧随其后的 `SessionEnd` 会保留这段完成提示；但 `done` 和 `SessionEnd` 都不会覆盖已有的 permission、blocked、attention、stale 或 paused。可以用 `AGENT_SIGNAL_LIGHT_COMPLETED_TTL_SECONDS` 调整这个停留时长。
如果状态文件此前处于 `off` / `stale`，新的非暂停 session 事件会恢复到对应状态，不会被旧 aggregate 锁住。

## 显示模式

状态栏图标有两个设置维度：风格和方向。

| 风格 | 外观 |
| --- | --- |
| 经典灯牌 | 和 App 预览一致，黑色胶囊底座，红黄绿三灯 |
| 极简圆点 | 透明背景小圆点，类似 iStat Menus 指示器 |

方向可以独立切换：

| 模式 | 外观 |
| --- | --- |
| 横向 | 红黄绿三灯横排 |
| 竖向 | 红黄绿三灯竖排 |

状态栏菜单默认只显示当前状态、最近事件、打开 Agent、设置、清除提醒、暂停监控和退出。所有开关、外观、尺寸对比、灯效、连接和诊断都归到 app 的设置窗口里。设置窗口使用顶部分类菜单切换 `运行`、`外观`、`灯效`、`连接`、`通用` 和 `关于`，分类顺序支持拖动调整并会记住。`运行` 里显示当前综合状态、实时监控状态、当前 Agent 会话和最近事件，方便判断是哪一个 Agent 或 hook 触发了状态灯。`通用` 里提供 `语言`、`主题`、`开机自启动`、`打开 Agent`、`清除提醒`、`显示状态栏信号` 和 Agent 来源；语言和主题默认 `跟随系统`，主题也可以手动切换为 `白色` 或 `黑色`。语言可以通过下拉菜单手动选择简体中文、繁体中文、英语、日语、韩语、西语、法语、德语和葡语。Agent 来源包含 Codex Desktop 本地自动监控、Codex / Claude Code Hook 接入，以及本地脚本和其他 Agent 的通用接入命令或 JSON 事件接入。状态栏图标设置了稳定的 AppKit autosave name，用户可以按住 `Command` 拖动状态栏信号灯调整位置，系统会记住位置。`打开 Agent` 菜单目前可打开 Codex 或 Claude。`连接` 里直接显示检查连接、安装连接、导出诊断、状态文件、路径和版本操作，不再藏在二级菜单里。设置窗口可以在 `外观` 里切换 `经典灯牌 / 极简圆点` 风格、`横向 / 竖向` 方向、`圆点横向尺寸` 和 `灯牌竖向尺寸`。默认外观是 `经典灯牌`、`横向`、`圆点横向尺寸：默认`、`灯牌竖向尺寸：默认`。`灯效` 里提供 `灯效自定义` 和 `灯效测试`：`灯效自定义` 可调 `运行灯效`、`运行速度`、`提醒闪烁速度`、`完成灯效` 和 `呼吸强度`，`灯效测试` 里有 `启用灯效测试` 总开关，关闭后只清除手动测试状态并恢复真实 Agent 状态；`状态栏全亮` 也归在这里，作为状态栏灯点预览开关。`运行灯效` 支持默认绿灯呼吸和红黄绿循环，`完成灯效` 支持绿灯慢闪、绿灯常亮、黄灯慢闪和黄灯常亮。`圆点横向尺寸` 提供 `默认 / 小`，默认会让极简圆点横向保持透明白圈外观，同时使用经典灯牌横向的状态栏占位、灯径和间距；`灯牌竖向尺寸` 提供 `默认 / 大`，大号会让经典灯牌竖向保留黑色底座，并使用适合菜单栏高度的最大可用紧凑尺寸。极简圆点的空心外圈固定为白色。状态栏图标由 AppKit `NSStatusItem` 创建，开关打开会创建状态栏项，关闭会移除状态栏项。从源码或 `dist/AgentSignalLight.app` 运行时，`安装连接` 会写入当前项目级 `.codex/hooks.json`，确保当前 Codex 项目能加载；如果 app 是从独立安装包资源运行、旁边没有项目 checkout，则会退回写入用户级 Codex hook。

可以在设置窗口的 `横向 / 竖向` 分段控件中切换。选择会持久保存到本机，下次启动继续使用。
如果你关闭了 `显示状态栏信号`，app 会立即打开设置窗口作为恢复入口；如果关闭这个窗口且状态栏信号仍关闭，app 会退出，避免在没有 Dock 图标和没有状态栏入口的情况下隐形运行。下次启动也会自动打开设置窗口。

## 运行

```bash
./script/build_and_run.sh
```

验证进程是否启动：

```bash
./script/build_and_run.sh --verify
```

打开设置窗口进行 UI 验证：

```bash
./script/build_and_run.sh --ui-verify
```

`--ui-verify` 会直接运行刚打包出的 `.app` 二进制并检查屏幕上确实出现 `Agent Signal Bar` 设置窗口，不只检查进程是否存在。
如果要验证菜单栏项本身已经创建、带图标、带点击 action 和 tooltip，可以运行：

```bash
./script/build_and_run.sh --status-item-verify
```

这个检查会临时强制打开状态栏信号，但不会改写你的持久偏好；它通过 app 写出的运行时健康 JSON 验证 `NSStatusItem`、button、image 和 action 都存在。

检查本机 CLI、hook、状态文件、app bundle 和开机自启动配置：

```bash
./script/doctor.sh
./script/doctor.sh --full
```

doctor 会只读检查当前项目 `.codex/hooks.json` 和 `~/.claude/settings.json` 是否指向当前 checkout 的 hook wrapper；用户级 `~/.codex/hooks.json` 是独立安装包的可选退回方案，如果存在旧的 Agent Signal Bar 条目也会提示迁移或清理。doctor 不会自动合并或覆盖你的现有 hook 配置。
`--full` 还会跑 core checks、app build 和测试套件；如果 `xcode-select` 当前指向 Command Line Tools，脚本会在存在完整 Xcode 时临时使用 `/Applications/Xcode.app/Contents/Developer`。
`--full` 也会单独验证状态栏图标的真实渲染像素：两种风格、横竖方向的灯语一致性，极简圆点呼吸动画在横竖布局里都有可见面积变化，`圆点横向尺寸：默认` 不会带入经典灯牌黑色底座，以及 `灯牌竖向尺寸：大` 仍保留经典灯牌底座并明显大于普通极简竖向三点。
`--full` 还会运行 DMG 安装验证：把 `dist/AgentSignalLight-local.dmg` 挂载到临时目录，复制 app 到临时 Applications，验证签名、release info、内置 CLI wrapper 和内置诊断导出脚本。
如果希望把 warning 也当成失败处理，可以运行 `./script/doctor.sh --full --strict`；这适合最终确认本机 hook、开机自启动和运行进程都处在预期状态时使用。

导出诊断包：

```bash
./script/export_diagnostics.sh
./script/export_diagnostics.sh --full
```

诊断包会写到 `dist/diagnostics/`，包含当前状态、状态 JSON、doctor 输出、hook dry-run、系统/Swift/Xcode 信息、app Info.plist、开机自启动 plist 副本，以及可用时的状态栏图标预览。设置窗口的 `连接` 里也有 `导出诊断` 按钮；导出成功后会在 Finder 中选中 zip。诊断包不会复制 `~/.codex/hooks.json` 或 `~/.claude/settings.json` 原文，hook 排查使用 dry-run 输出，避免无意带出整份本机配置。

设置窗口的 `连接` 里会显示签名/公证状态。`版本` 按钮会在 Finder 中选中 `AgentSignalLight-release-manifest.json`；如果 app 是从 DMG 安装、旁边没有完整 manifest，则会选中 app 内置的 `AgentSignalLight-release-info.json`。旁边的复制按钮会复制版本和发布信息，方便排查“我现在跑的是哪一版”。

导出状态栏图标视觉预览：

```bash
swift run agent-signal-icon-preview
```

默认会生成 `dist/status-icon-preview/status-icon-preview.png`、逐个状态栏 icon PNG，以及 `manifest.json`。这些预览直接复用 app 的 `StatusBarIconRenderer`，适合在改颜色、间距、呼吸强度或横竖布局后做人工对比。

安全预览并安装 Codex / Claude Code hook 配置：

```bash
./script/install_hooks.py --target all --codex-scope project --dry-run
./script/install_hooks.py --target all --codex-scope project --install
```

当前项目开发时建议用 `--codex-scope project`，避免项目级和用户级 Codex hook 同时触发。

安装脚本会保留已有 JSON 字段，只把当前 checkout 或当前 app bundle 的 hook command 合并到缺失事件里；已有配置文件会先生成 `.bak-YYYYmmddHHMMSS` 备份。如果之前配置过旧路径的 Agent Signal Bar wrapper，安装脚本会迁移到当前 wrapper 路径，避免重复触发。项目级 `.codex/hooks.json` 包含本机绝对路径，默认被 `.gitignore` 忽略。

Codex 桌面端的 Run action 已指向同一个脚本。

安装到当前用户的 Applications，并可选开机自启动：

```bash
./script/install_app.sh --login-item
```

如果 `dist/AgentSignalLight.app` 已经存在，安装脚本会直接复制这个 app，不会重新编译；这让 release zip 可以在没有 Xcode 的机器上安装。需要强制重新构建时使用 `./script/install_app.sh --rebuild`。需要从 DMG 安装时使用：

```bash
./script/install_app.sh --dmg dist/AgentSignalLight-local.dmg
```

也可以在设置窗口里切换 `开机自启动`。

卸载：

```bash
./script/uninstall_app.sh
./script/uninstall_app.sh --remove-hooks
```

默认卸载只移除 app 和开机自启动项，保留 Codex / Claude Code hook 配置。加 `--remove-hooks` 会从 `~/.codex/hooks.json` 和 `~/.claude/settings.json` 中移除 Agent Signal Bar hook，并在写入前生成备份；用户自己的其它 hook 会保留。
`--purge-state` 会删除状态目录，默认是 `/tmp/agent-signal`；需要测试或自定义状态目录时可设置 `AGENT_SIGNAL_LIGHT_STATE_DIR`。`--no-kill` 和 `--no-launchctl` 主要用于临时目录验证，避免影响正在运行的真实 app 或登录项。自动卸载验收可以运行：

```bash
./script/verify_uninstall.sh
```

一键本地发布验收：

```bash
./script/verify_release_all.sh
```

这个命令会生成 release zip/DMG，运行 Swift 测试、checksum 校验、zip 独立安装验证、DMG 安装验证、卸载演练和 `doctor --full`。如果已经生成过产物，只想快速重跑验收，可以用 `./script/verify_release_all.sh --skip-package`；需要把设置窗口的真实屏幕检测和状态栏项运行时健康检查也纳入同一轮验收时，加 `--ui`。最终本机交付前可以再加 `--strict-doctor`，让 `doctor` 的 warning 也会让总验收失败。

生成本地可分发成品包：

```bash
./script/package_release.sh
```

产物会写到 `dist/AgentSignalLight-local.zip` 和 `dist/AgentSignalLight-local.dmg`，并生成 `dist/AgentSignalLight-release-manifest.json` 与 `dist/AgentSignalLight-SHA256SUMS.txt`。manifest 会记录 app 版本、构建时间、签名模式、notary readiness、zip/DMG 的大小和 sha256，方便交付回溯。zip 内包含源码、测试、`dist/AgentSignalLight.app`、release 版 CLI、hook wrapper、hook 安装脚本、诊断导出脚本和文档；DMG 用于日常安装，里面有 `AgentSignalLight.app`、`Applications` 快捷方式和简短 Read Me。app bundle 自身也会内置 release 版 CLI、hook wrapper、hook 安装脚本和诊断导出脚本，所以复制到 `~/Applications` 后仍可从 App 内执行 `检查连接` / `安装连接` / `导出诊断`。app bundle 会包含 `AppIcon.icns` 并做本机 ad-hoc 签名；这是本地分发/自用包，不等同于 Apple Developer ID 公证包。
release zip 还会包含 `dist/status-icon-preview/`，用于快速查看状态栏图标在所有核心灯语、两种风格和横竖方向下的视觉表现。

只生成 DMG：

```bash
./script/package_dmg.sh
```

验证 DMG 安装后的 app bundle：

```bash
./script/verify_release_install.sh
```

默认只做非侵入式检查，不会启动 app。需要验证临时安装副本能启动时，可以显式运行 `./script/verify_release_install.sh --launch`。

验证 release zip 解压后可以独立安装：

```bash
./script/verify_release_zip.sh
```

这个检查会把 zip 解压到临时目录，从解压后的 payload 运行 `script/install_app.sh --no-open`，并确认安装过程没有重新构建 `.build`，适合验证“发给别人一个 zip，对方不用 Xcode 也能装”。

`verify_release_all.sh --launch` 会额外让 zip/DMG 验证脚本启动临时安装副本，适合最终交付前做一次更接近用户安装后的检查。

Developer ID 签名和公证准备检查：

```bash
./script/notarize_release.sh --readiness
```

如果本机已经有 `Developer ID Application` 证书，并且已经用 `xcrun notarytool store-credentials` 保存过 notarytool profile，可以用下面的流程生成外发版 DMG 并提交公证：

```bash
AGENT_SIGNAL_LIGHT_CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./script/package_release.sh

AGENT_SIGNAL_LIGHT_NOTARY_PROFILE="agent-signal-light" \
  ./script/notarize_release.sh --submit
```

没有 Developer ID 证书时，`package_release.sh` 会继续生成本地自用的 ad-hoc 签名 zip/DMG；`notarize_release.sh --readiness` 会明确列出缺少的证书或 notarytool profile，不会假装已经公证。

## CLI

先安装 release 版 CLI，避免 hook 第一次触发时临时编译：

```bash
./script/install_cli.sh
```

CLI 支持直接用 signal 名称更新状态：

```bash
./scripts/agent-signal idle
./scripts/agent-signal working --session codex-main --agent codex --event PreToolUse
./scripts/agent-signal attention --session codex-main --event Notification
./scripts/agent-signal permission --session codex-main --event PermissionRequest
./scripts/agent-signal blocked --session codex-main --event PostToolUseFailure
./scripts/agent-signal done --session codex-main --event Stop
./scripts/agent-signal clear-warning
./scripts/agent-signal reset
```

不带 `--session` 的裸 signal 命令会写入 `manual` session，因此也会参与同一套聚合优先级；例如已有 `permission` session 时，`agent-signal working` 不会把红灯覆盖掉。`idle` / `reset` 仍然是手动清空并回到空闲。
CLI 会拒绝未知选项和缺少值的选项，避免把 `--session` 拼错或漏填时静默退化成 `manual` session。

本地脚本也可以用 `agent-signal-run` 包住任意命令，自动处理开始、成功和失败状态，并保留原命令退出码：

```bash
./scripts/agent-signal-run \
  --session nightly-build \
  --agent script \
  -- ./run-build.sh
```

其它 agent 可以直接把 JSON 事件交给通用 hook。它会读取 `event/status/signal`、`agent/source` 和 `session_id/task_id/run_id` 等常见字段：

```bash
echo '{"event":"AgentStarted","agent":"local-script","session_id":"local-script-main"}' \
  | ./scripts/generic-agent-signal-hook

echo '{"event":"ApprovalRequired","source":"local-agent","task_id":"task-1"}' \
  | ./scripts/generic-agent-signal-hook
```

`clear-warning` 只清除 `permission/blocked/attention/notification/stale` 这类需要处理或状态不可信的 session，会保留仍在 `working/thinking/tool_done` 的 active session。`done` 是绿色 completed，不再作为黄色 warning 清除，并会按 completed TTL 自动回到 idle。`reset` 会回到空闲并清空所有 session。

设置窗口的 `灯效` 里提供 `灯效自定义` 和 `灯效测试`。`灯效自定义` 可调整运行灯效、运行速度、提醒闪烁速度、完成灯效和呼吸强度；`灯效测试` 提供 `idle`、`working`、`attention`、`done`、`permission`、`blocked`、`off` 的手动按钮，并在 `高级信号` 里提供 `thinking`、`tool_done`、`subagent_start`、`subagent_stop`、`notification`、`permission_request`、`stale`、`pause`、`session_start`、`session_end` 和 `turn_end`。测试按钮需要先打开 `启用灯效测试`，关闭该开关会退出测试模式，只移除手动测试 session，不会清除真实 Agent session。

查看当前状态：

```bash
./scripts/agent-signal status
./scripts/agent-signal status --json
```

脚本需要机器可读结果时，可以在会输出状态的命令后加 `--json`：

```bash
./scripts/agent-signal working --session job --agent script --event Started --json
```

JSON 输出包含 `aggregate`、`display_state`、`lamp_state`、`priority`、`action`、`sessions` 和 `recent_events`，适合给其他自动化脚本判断是否需要提醒。`lamp_state` 为兼容旧脚本保留，值与 `display_state` 一致。

## 状态文件

默认状态文件：

```text
/tmp/agent-signal/status.json
```

示例：

```json
{
  "schema_version": 1,
  "aggregate": "permission",
  "updated_at": "2026-05-28T03:45:00Z",
  "sessions": {
    "codex-main": {
      "agent": "codex",
      "signal": "permission",
      "last_event": "PermissionRequest",
      "updated_at": "2026-05-28T03:44:50Z"
    }
  },
  "events": [
    {
      "id": "D4204E0A-5B5D-4DFB-A3BC-643E6C7C6F8F",
      "session_id": "codex-main",
      "agent": "codex",
      "signal": "permission",
      "event": "PermissionRequest",
      "updated_at": "2026-05-28T03:44:50Z"
    }
  ]
}
```

可用环境变量覆盖：

```bash
export AGENT_SIGNAL_LIGHT_STATE_FILE=/path/to/status.json
export AGENT_SIGNAL_LIGHT_STATE_DIR=/tmp/agent-signal
export AGENT_SIGNAL_LIGHT_EVENT_LIMIT=30
```

## Hook

Codex:

```bash
./scripts/codex-signal-hook UserPromptSubmit
./scripts/codex-signal-hook PreToolUse
./scripts/codex-signal-hook PermissionRequest
./scripts/codex-signal-hook Stop
```

Claude Code:

```bash
echo '{"event":"PreToolUse","session_id":"demo"}' | ./scripts/claude-code-signal-hook
echo '{"event":"PermissionRequest","session_id":"demo"}' | ./scripts/claude-code-signal-hook
```

Generic Agent / local runner:

```bash
echo '{"event":"AgentStarted","agent":"local-script","session_id":"local-script-main"}' | ./scripts/generic-agent-signal-hook
echo '{"event":"AgentFinished","agent":"local-script","session_id":"local-script-main"}' | ./scripts/generic-agent-signal-hook
echo '{"event":"ApprovalRequired","source":"local-agent","task_id":"task-1"}' | ./scripts/generic-agent-signal-hook
```

更多配置见 [docs/LAMP_LANGUAGE.md](docs/LAMP_LANGUAGE.md)、[docs/STATE_SCHEMA.md](docs/STATE_SCHEMA.md)、[docs/CODEX_SETUP.md](docs/CODEX_SETUP.md)、[docs/CLAUDE_CODE_SETUP.md](docs/CLAUDE_CODE_SETUP.md)、[docs/LOCAL_SCRIPT_SETUP.md](docs/LOCAL_SCRIPT_SETUP.md)。
交付前检查见 [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md)。
