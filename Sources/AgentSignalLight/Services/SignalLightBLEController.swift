import AgentSignalLightCore
import Combine
import Foundation

// MARK: - 协议（测试可注入 Fake，参考 OpenAIBrowserCookieImporting 模式）

/// 扫描发现的蓝牙信号灯设备（供 UI 列表展示）。
public struct SignalLightBLEDevice: Sendable, Equatable, Identifiable {
    public let id: String      // CBPeripheral.identifier UUID 字符串
    public let name: String?   // 设备名（如 coding-abc123）

    public init(id: String, name: String?) {
        self.id = id
        self.name = name
    }
}

/// 蓝牙信号灯硬件控制协议：把 CoreBluetooth 的扫描/连接/写入藏在后面，测试不接触真实 CoreBluetooth。
public protocol SignalLightBLECommanding: Sendable {
    /// 当前是否已连接设备（用于 UI 状态展示）。
    var isConnected: Bool { get async }
    /// 最近一次成功连接的设备标识（CBPeripheral.identifier UUID 字符串）。
    /// 连接成功后由 commander 设置；controller 据此持久化到 UserDefaults。
    /// 测试用 commander 可在 scanAndConnect/reconnect 成功后设置此值。
    var lastConnectedDeviceID: String? { get async }
    /// 当前已连接设备的显示名（供 UI 显示「已连接: <name>」）。
    var connectedDeviceName: String? { get async }
    /// 扫描 `coding-` 前缀设备并连接到第一个找到的设备；返回是否连接成功。
    /// 失败只记录日志，不抛错（按 Issue #2 验收：连接/写入失败只记日志，不弹用户可见错误）。
    func scanAndConnect() async -> Bool
    /// 扫描附近的 `coding-` 前缀设备，返回发现的设备列表（不自动连接）。
    /// 供 UI 展示设备选择菜单（Issue #5）。
    func scanForDevices() async -> [SignalLightBLEDevice]
    /// 连接到指定 ID 的设备（用户从菜单选择后调用）；返回是否连接成功。
    func connect(toDeviceID deviceID: String) async -> Bool
    /// 用已保存的设备 ID 直接重连（不经扫描），返回是否连接成功。
    /// CoreBluetooth 实现用 `retrievePeripherals(withIdentifiers:)` + `connect`。
    /// 若 ID 无效或设备不可达，返回 false（caller 会 fall back 到 scanAndConnect）。
    func reconnect(toDeviceID deviceID: String) async -> Bool
    /// 写入一条 BLE 命令到已连接设备的 Nordic UART Service RX 特征。
    /// 未连接或写入失败时返回 false（仅记日志）。
    func send(_ command: SignalLightBLECommand) async -> Bool
    /// 断开当前连接并停止扫描。
    func disconnect() async
    /// 设置断连回调：当 CoreBluetooth 检测到意外断连（`didDisconnectPeripheral`）时触发，
    /// 让上层（`SignalLightBLEController`）启动重连流程。
    /// 测试用 commander 可空实现；生产 commander 必须在断连时调用。
    func setOnDisconnect(_ handler: @escaping @Sendable () async -> Void)
}

// MARK: - UI / Controller 用的连接状态

/// 蓝牙信号灯连接状态（供 UI 显示按钮三态：扫描 / 连接中 / 已连接）。
public enum SignalLightBLEConnectionState: Sendable, Equatable {
    case disabled           // 开关关闭
    case idle              // 开关开但未连接、未在扫描
    case scanning          // 正在扫描设备
    case connecting        // 正在连接（含自动重连）
    case connected(deviceName: String?)  // 已连接
}

// MARK: - Controller

/// 蓝牙信号灯 Service：与 `StatusBarController` / `FloatingSignalWindowController` 平级，
/// 订阅 `MenuBarStatusModel.$snapshot`，把 `aggregate.displayState` 映射成 `SignalLightBLECommand`
/// 写入硬件。不引入 TCP daemon（见 ADR-0002）。
///
/// `isSignalLightBLEEnabled` 开关默认关闭；关闭时完全不初始化 `CBCentralManager`，
/// 避免无硬件用户被蓝牙权限弹窗打扰。
///
/// 重连策略（Issue #3，cpets `ble_worker.py`）：断连后前 5 次每 2 秒重试一次，
/// 之后每 30 秒轮询一次，无限重试，直到连接成功或用户主动断开。
/// 写入失败也视为断连，立即触发重连，不等 `didDisconnectPeripheral` 回调。
@MainActor
final class SignalLightBLEController: ObservableObject {
    /// UserDefaults key：持久化最后连接的设备 ID（单 slot，覆盖式，见 ADR-0002）。
    static let lastDeviceIDKey = "signalLightBELastDeviceID"

    private let model: MenuBarStatusModel
    private var commander: SignalLightBLECommanding
    private let clock: SignalLightBLEClock
    private var cancellables = Set<AnyCancellable>()
    private var lastSentCommand: SignalLightBLECommand?
    private var isActivated = false

    // 扫描状态保护：记录进入 .scanning 的时间，避免异常情况下 UI 永远卡在 scanning。
    private var scanningStartTime: Date?
    private let scanningStateTimeout: TimeInterval

    // 重连状态机
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttemptCount = 0
    /// 标记用户主动断开（开关关闭或点断开按钮），阻止重连流程。
    private var isUserInitiatedDisconnect = false

    /// 当前连接状态（供 DebugWindowView 三态按钮展示）。
    @Published private(set) var connectionState: SignalLightBLEConnectionState = .disabled

    init(
        model: MenuBarStatusModel,
        commander: SignalLightBLECommanding,
        clock: SignalLightBLEClock = SystemSignalLightBLEClock(),
        scanningStateTimeout: TimeInterval = 10.0
    ) {
        self.model = model
        self.commander = commander
        self.clock = clock
        self.scanningStateTimeout = scanningStateTimeout
        // 把 commander 的断连回调接到自己的重连入口。
        // 用 Task 跳出 delegate 调用栈，避免回调中再次触发 CoreBluetooth 操作导致重入。
        commander.setOnDisconnect { [weak self] in
            await MainActor.run {
                self?.handleDisconnect()
            }
        }
    }

    deinit {
        reconnectTask?.cancel()
    }

    /// 在应用启动后调用（与 `StatusBarController.activate()` 平级）。
    /// 订阅偏好开关与 snapshot；开关关闭时不做任何 CoreBluetooth 操作。
    func activate() {
        guard !isActivated else { return }
        isActivated = true
        Task { @MainActor in
            await updateConnectionState()
        }

        // 开关变化：开启则尝试启动重连（若有保存的设备 ID）或同步状态，关闭则断开。
        model.$isSignalLightBLEEnabled.sink { [weak self] enabled in
            Task { @MainActor in
                guard let self else { return }
                if enabled {
                    self.isUserInitiatedDisconnect = false
                    // 开关开启时：若有保存的设备 ID，走定向重连；否则只同步状态（无连接，send 失败会触发 scan）。
                    if let savedID = self.savedLastDeviceID() {
                        self.startReconnect(deviceID: savedID)
                    } else {
                        await self.syncCurrentState()
                    }
                } else {
                    await self.userDisconnect()
                }
                await self.updateConnectionState()
            }
        }
        .store(in: &cancellables)

        // snapshot 变化：映射到 BLE 命令并写入（仅当开关开启时）。
        model.$snapshot.sink { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.model.isSignalLightBLEEnabled else { return }
                let command = snapshot.aggregate.displayState.bleCommand
                // 命令级去重（Issue #6）：基于 BLE 命令字符串比较，相同命令不重复写入，
                // 吸收 aggregate 在映射到同一命令的状态间 churn（如 active ↔ completed 都是 GREEN）。
                guard command != self.lastSentCommand else { return }
                self.lastSentCommand = command
                // 写入失败视为隐式断连，立即触发重连（不等 didDisconnectPeripheral 回调）。
                let ok = await self.commander.send(command)
                if !ok {
                    self.handleDisconnect()
                }
                await self.updateConnectionState()
            }
        }
        .store(in: &cancellables)
    }

    /// 用户在 DebugWindowView 点「扫描」按钮触发：扫描附近 `coding-` 设备。
    /// 返回发现的设备列表（UI 展示为菜单供用户选择）。
    @discardableResult
    func scanForDevices() async -> [SignalLightBLEDevice] {
        guard model.isSignalLightBLEEnabled else { return [] }
        connectionState = .scanning
        scanningStartTime = Date()
        let devices = await commander.scanForDevices()
        // 扫描完成后回到 idle（用户选设备时 UI 会展示菜单）
        if connectionState == .scanning {
            connectionState = .idle
        }
        scanningStartTime = nil
        return devices
    }

    /// 用户从菜单选择设备后连接。返回是否连接成功。
    @discardableResult
    func connect(to deviceID: String) async -> Bool {
        guard model.isSignalLightBLEEnabled else { return false }
        connectionState = .connecting
        let ok = await commander.connect(toDeviceID: deviceID)
        if ok {
            isUserInitiatedDisconnect = false
            persistLastDeviceID()
            reconnectAttemptCount = 0
            await syncCurrentState()
        }
        await updateConnectionState()
        return ok
    }

    /// 用户在 DebugWindowView 点「断开」按钮触发：主动断开，停止重连。
    func disconnect() {
        guard model.isSignalLightBLEEnabled else { return }
        Task { @MainActor in
            await self.userDisconnect()
            await self.updateConnectionState()
        }
    }

    /// 用户点「扫描连接」按钮触发（保留旧 API 兼容旧测试，内部转 scanAndConnect 第一台）。
    func scanAndConnect() {
        guard model.isSignalLightBLEEnabled else { return }
        Task { @MainActor in
            self.connectionState = .connecting
            let ok = await self.commander.scanAndConnect()
            if ok {
                self.isUserInitiatedDisconnect = false
                self.persistLastDeviceID()
                self.reconnectAttemptCount = 0
                await self.syncCurrentState()
            }
            await self.updateConnectionState()
        }
    }

    /// 把当前 snapshot 状态映射成命令并发送一次。
    /// 重连/连接成功后强制重写一次（约定基线：硬件状态可能丢失）。
    private func syncCurrentState() async {
        let command = model.snapshot.aggregate.displayState.bleCommand
        lastSentCommand = command
        _ = await commander.send(command)
    }

    /// 用户主动断开（开关关闭或点断开按钮）：取消重连，标记不重连，commander 断开。
    private func userDisconnect() async {
        isUserInitiatedDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttemptCount = 0
        await commander.disconnect()
        lastSentCommand = nil
        // 注意：不清空保存的设备 ID —— 用户下次开启开关时仍可自动重连到同一设备。
        // 设备 ID 只在新设备连接成功时被覆盖（acceptance: 换设备覆盖）。
    }

    /// 启动重连流程，优先用保存的设备 ID 定向重连，失败回退到扫描。
    /// 若已在重连流程中或用户主动断开，则不重复启动。
    private func startReconnect(deviceID: String?) {
        // 用户主动断开时不重连。
        guard !isUserInitiatedDisconnect else { return }
        // 已在重连流程中，不重复启动。
        if reconnectTask != nil { return }
        // 开关关闭时不重连。
        guard model.isSignalLightBLEEnabled else { return }

        connectionState = .connecting
        reconnectTask = Task { @MainActor in
            while !Task.isCancelled {
                let attempt = self.reconnectAttemptCount
                self.reconnectAttemptCount += 1
                // 优先用保存的设备 ID 定向重连；无 ID 或失败则回退到扫描。
                var ok: Bool
                if let deviceID {
                    ok = await self.commander.reconnect(toDeviceID: deviceID)
                    if !ok {
                        // 定向重连失败（设备未在系统缓存中）→ 回退到扫描。
                        ok = await self.commander.scanAndConnect()
                    }
                } else {
                    ok = await self.commander.scanAndConnect()
                }
                if ok {
                    // 重连成功：保存设备 ID（可能换了设备），清零计数，同步状态，退出重连循环。
                    self.persistLastDeviceID()
                    self.reconnectAttemptCount = 0
                    await self.syncCurrentState()
                    self.reconnectTask = nil
                    await self.updateConnectionState()
                    return
                }
                // 按 policy 等待后重试。
                let interval = SignalLightBLEReconnectPolicy.interval(forAttempt: attempt)
                await self.clock.sleep(seconds: interval)
            }
            // 被 cancel（用户主动断开）：清空 task 引用。
            self.reconnectTask = nil
            await self.updateConnectionState()
        }
    }

    /// 断连处理入口（两个触发源：commander.onDisconnect 回调 + send 失败）。
    /// 若已在重连流程中或用户主动断开，则不重复启动。
    private func handleDisconnect() {
        startReconnect(deviceID: savedLastDeviceID())
    }

    /// 根据 commander 状态同步 connectionState（供 UI 三态展示）。
    private func updateConnectionState() async {
        guard model.isSignalLightBLEEnabled else {
            connectionState = .disabled
            return
        }
        // 正在扫描/连接中时保持原状态，避免被覆盖；
        // 但如果扫描状态已超时（异常 stuck），则降级到 idle，防止 UI 永远卡住。
        if case .scanning = connectionState {
            if let startTime = scanningStartTime,
               Date().timeIntervalSince(startTime) > scanningStateTimeout {
                connectionState = .idle
                scanningStartTime = nil
            } else {
                return
            }
        }
        if reconnectTask != nil {
            connectionState = .connecting
            return
        }
        // 异步读取连接状态；await 期间可能启动重连，因此读取后再次检查。
        let connected = await commander.isConnected
        if reconnectTask != nil {
            connectionState = .connecting
            return
        }
        if connected {
            let name = await commander.connectedDeviceName
            connectionState = .connected(deviceName: name)
        } else {
            connectionState = .idle
        }
    }

    // MARK: - 设备 ID 持久化（UserDefaults 单 slot，覆盖式）

    private func savedLastDeviceID() -> String? {
        UserDefaults.standard.string(forKey: Self.lastDeviceIDKey)
    }

    /// 从 commander 读取当前连接的设备 ID 并保存到 UserDefaults。
    /// 连接新设备时覆盖旧值（acceptance: 只记一个设备）。
    private func persistLastDeviceID() {
        Task { @MainActor in
            if let id = await self.commander.lastConnectedDeviceID {
                UserDefaults.standard.set(id, forKey: Self.lastDeviceIDKey)
            }
        }
    }
}
