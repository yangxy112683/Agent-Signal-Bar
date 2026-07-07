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
