import AgentSignalLightCore
import Combine
import Foundation

// MARK: - 协议（测试可注入 Fake，参考 OpenAIBrowserCookieImporting 模式）

/// 蓝牙信号灯硬件控制协议：把 CoreBluetooth 的扫描/连接/写入藏在后面，测试不接触真实 CoreBluetooth。
public protocol SignalLightBLECommanding: Sendable {
    /// 当前是否已连接设备（用于 UI 状态展示）。
    var isConnected: Bool { get async }
    /// 扫描 `coding-` 前缀设备并连接到第一个找到的设备；返回是否连接成功。
    /// 失败只记录日志，不抛错（按 Issue #2 验收：连接/写入失败只记日志，不弹用户可见错误）。
    func scanAndConnect() async -> Bool
    /// 写入一条 BLE 命令到已连接设备的 Nordic UART Service RX 特征。
    /// 未连接或写入失败时返回 false（仅记日志）。
    func send(_ command: SignalLightBLECommand) async -> Bool
    /// 断开当前连接并停止扫描。
    func disconnect() async
}

// MARK: - UI / Controller 用的连接状态

/// 蓝牙信号灯连接状态（供 UI 显示按钮三态：未启用 / 扫描中 / 已连接 / 失败）。
public enum SignalLightBLEConnectionState: Sendable, Equatable {
    case disabled
    case disconnected
    case scanning
    case connected(deviceName: String?)
    case failed(reason: String)
}

// MARK: - Controller

/// 蓝牙信号灯 Service：与 `StatusBarController` / `FloatingSignalWindowController` 平级，
/// 订阅 `MenuBarStatusModel.$snapshot`，把 `aggregate.displayState` 映射成 `SignalLightBLECommand`
/// 写入硬件。不引入 TCP daemon（见 ADR-0002）。
///
/// `isSignalLightBLEEnabled` 开关默认关闭；关闭时完全不初始化 `CBCentralManager`，
/// 避免无硬件用户被蓝牙权限弹窗打扰。
@MainActor
final class SignalLightBLEController {
    private let model: MenuBarStatusModel
    private let commander: SignalLightBLECommanding
    private var cancellables = Set<AnyCancellable>()
    private var lastSentCommand: SignalLightBLECommand?
    private var isActivated = false

    init(model: MenuBarStatusModel, commander: SignalLightBLECommanding) {
        self.model = model
        self.commander = commander
    }

    /// 在应用启动后调用（与 `StatusBarController.activate()` 平级）。
    /// 订阅偏好开关与 snapshot；开关关闭时不做任何 CoreBluetooth 操作。
    func activate() {
        guard !isActivated else { return }
        isActivated = true

        // 开关变化：开启则触发一次状态同步，关闭则断开并清空已发送命令。
        model.$isSignalLightBLEEnabled.sink { [weak self] enabled in
            Task { @MainActor in
                guard let self else { return }
                if enabled {
                    await self.syncCurrentState()
                } else {
                    await self.commander.disconnect()
                    self.lastSentCommand = nil
                }
            }
        }
        .store(in: &cancellables)

        // snapshot 变化：映射到 BLE 命令并写入（仅当开关开启时）。
        model.$snapshot.sink { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.model.isSignalLightBLEEnabled else { return }
                let command = snapshot.aggregate.displayState.bleCommand
                // 命令级去重的完整实现在 Issue #6；这里只做最小化避免重复写入相同命令，
                // 防止 snapshot 高频刷新时把硬件打爆。这是 Slice 1 的最小必要保护。
                guard command != self.lastSentCommand else { return }
                self.lastSentCommand = command
                _ = await self.commander.send(command)
            }
        }
        .store(in: &cancellables)
    }

    /// 用户在 DebugWindowView 点「扫描连接」按钮触发。
    func scanAndConnect() {
        guard model.isSignalLightBLEEnabled else { return }
        Task { @MainActor in
            let ok = await self.commander.scanAndConnect()
            if ok {
                // 连接成功后立即把当前状态同步到硬件。
                await self.syncCurrentState()
            }
        }
    }

    /// 把当前 snapshot 状态映射成命令并发送一次。
    private func syncCurrentState() async {
        let command = model.snapshot.aggregate.displayState.bleCommand
        lastSentCommand = command
        _ = await commander.send(command)
    }
}
