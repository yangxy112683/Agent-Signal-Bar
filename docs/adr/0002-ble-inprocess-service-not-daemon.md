---
status: accepted
---

# 硬件信号灯的蓝牙控制做成 app 内进程内 Service，不做独立 daemon

cpets（Windows 桌宠项目）的 GUI 和 CLI 是两个独立进程，必须靠本地 TCP daemon 把控灯指令从 CLI 转发给常驻的 GUI 进程。但 agent-signal-bar 的 hook（无论从哪个终端/IDE 触发）本来就只是写状态文件的短命子进程，跨进程通信已经由状态文件 + `StateFileWatcher` 解决，常驻的菜单栏 app 进程内直接就能拿到聚合后的 `MenuBarStatusModel.snapshot.aggregate`。因此硬件信号灯的蓝牙控制实现为 app 内部一个新 Service（`SignalLightBLEController`，`Sources/AgentSignalLight/Services/`），直接订阅 `model.$snapshot`，与 `StatusBarController`、`FloatingSignalWindowController` 平级，不引入额外的 daemon 进程、TCP 监听或 IPC 通道。

考虑过的替代方案：照搬 cpets 的 TCP daemon 架构，让蓝牙控制独立于 app 主进程运行。放弃的原因——当前所有触发源都不需要绕开 app 直接控光，额外起一个 daemon 进程只会增加部署复杂度和潜在的端口冲突风险，没有对应的真实需求。

后续如果出现"需要在 app 未运行时也能通过命令行直接控灯"的需求，需要重新评估这个决策。

## 附加决策

**只支持单设备**：与 cpets 的设计一致（`_last_addr` 单字段），`UserDefaults` 只保存一个设备标识，重新连接其他设备会覆盖旧记录，不维护设备列表。当前只有"一人一个桌面指示灯"的场景，多硬件同步显示不是本决策要覆盖的需求；如果后续出现多硬件场景，需要重新设计存储结构。

**默认关闭的总开关**：新增 `isSignalLightBLEEnabled`（默认 `false`）。`SignalLightBLEController` 只有在开关打开时才初始化 `CBCentralManager`；开关关闭时完全不触发 macOS 蓝牙权限弹窗。这是刻意的取舍——多数用户没有这个硬件，不应该被无关的权限请求打扰，即使这意味着有硬件的用户需要多一步手动开启。
