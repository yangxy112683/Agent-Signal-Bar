import AgentSignalLightCore
import Foundation
import os.log

#if os(macOS)
import CoreBluetooth

/// `SignalLightBLECommanding` 的 CoreBluetooth 实现。
///
/// 协议常量与 cpets 参考项目一致：
/// - 设备名前缀：`coding-`
/// - Nordic UART Service RX 特征（写入）：`6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
/// - Nordic UART Service TX 特征（通知）：`6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
/// - 命令：大写 ASCII 文本，以 `\n` 结尾
///
/// 所有连接/写入失败都通过 `Logger` 记录，不抛错、不弹 UI（按 Issue #2 验收）。
///
/// 所有连接/写入失败都通过 `Logger` 记录，不抛错、不弹 UI（按 Issue #2 验收）。
///
/// 整个类型隔离在 `@MainActor`；`CBCentralManager` 用 main queue 回调，
/// delegate 方法直接在主线程执行，所有可变状态安全隔离。
@MainActor
public final class CoreBluetoothSignalLightCommander: NSObject {
    private let deviceNamePrefix = "coding-"
    private let uartServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let uartRXCharacteristicUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let uartTXCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    private let logger = Logger(subsystem: "com.agent-signal-bar", category: "BLE")
    private let central: CBCentralManager
    /// scanForDevices() 的扫描时长（秒），默认 3 秒；可通过 init 注入以支持测试或不同场景。
    private let scanDuration: TimeInterval

    private var connectedPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    /// scanAndConnect/reconnect 成功（特征就绪）后设置，标识当前连接的设备。
    private var lastConnectedDeviceIDValue: String?
    private var scanContinuation: CheckedContinuation<Bool, Never>?
    private var writeContinuation: CheckedContinuation<Bool, Never>?
    /// scanForDevices() 的列表收集 continuation（与 scanAndConnect 的单设备 continuation 互斥使用）。
    private var scanListContinuation: CheckedContinuation<[SignalLightBLEDevice], Never>?
    /// scanForDevices() 期间发现的设备（去重）。
    private var discoveredDevices: [SignalLightBLEDevice] = []
    // 断连回调：让上层 controller 启动重连流程。
    private var onDisconnectHandler: (@Sendable () async -> Void)?
    /// 主动重连中：connectToKnownPeripheral 会先 cancel 现有连接，
    /// 这会触发一次 didDisconnectPeripheral。该回调只做状态清理，
    /// 不再通知上层启动重连（否则会和调用方正在跑的重连流程互相干扰）。
    private var isReconnecting = false

    public init(scanDuration: TimeInterval = 5.0) {
        // 用 main queue 让 CoreBluetooth 的 delegate 回调直接在主线程执行，
        // 这样所有可变状态都可以安全地隔离在 MainActor 上，无需 Task 跳转。
        self.scanDuration = scanDuration
        central = CBCentralManager(delegate: nil, queue: .main)
        super.init()
        central.delegate = self
    }
}

// MARK: - SignalLightBLECommanding

extension CoreBluetoothSignalLightCommander: @preconcurrency SignalLightBLECommanding {
    public var isConnected: Bool {
        connectedPeripheral != nil && rxCharacteristic != nil
    }

    public var lastConnectedDeviceID: String? {
        lastConnectedDeviceIDValue
    }

    public var connectedDeviceName: String? {
        connectedPeripheral?.name
    }

    public func scanAndConnect() async -> Bool {
        // 已连接（且特征就绪）则直接成功。
        // 用 isConnected 而非 connectedPeripheral，避免僵尸态被当成已连接而跳过真正的连接。
        if isConnected { return true }
        // 等待蓝牙权限就绪（poweredOn）。
        guard await waitForPoweredOn() else {
            logger.error("BLE 蓝牙未就绪，放弃扫描")
            return false
        }
        if isConnected { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            scanContinuation = continuation
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    public func scanForDevices() async -> [SignalLightBLEDevice] {
        await scanForDevices(filterByService: false)
    }

    public func scanForDevices(filterByService: Bool) async -> [SignalLightBLEDevice] {
        guard await waitForPoweredOn() else {
            logger.error("BLE 蓝牙未就绪，放弃扫描设备列表")
            return []
        }
        // 扫描 3 秒收集所有 coding- 设备，不自动连接。
        let discovered: [SignalLightBLEDevice] = await withCheckedContinuation { continuation in
            scanListContinuation = continuation
            discoveredDevices = []
            central.scanForPeripherals(
                withServices: filterByService ? [uartServiceUUID] : nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
            // 按配置时长停止扫描并返回结果
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(self.scanDuration * 1_000_000_000))
                self.central.stopScan()
                let devices = self.discoveredDevices
                self.discoveredDevices = []
                if let cont = self.scanListContinuation {
                    self.scanListContinuation = nil
                    cont.resume(returning: devices)
                }
            }
        }
        return discovered
    }

    public func connect(toDeviceID deviceID: String) async -> Bool {
        // 已连接且是同一设备则直接成功。
        if let connected = connectedPeripheral, connected.identifier.uuidString == deviceID {
            return true
        }
        return await connectToKnownPeripheral(deviceID: deviceID, logPrefix: "BLE connect")
    }

    public func reconnect(toDeviceID deviceID: String) async -> Bool {
        // 已连接（且特征就绪）则直接成功。
        // 用 isConnected 而非 connectedPeripheral，否则僵尸态会让重连假成功、永远不真正重连。
        if isConnected { return true }
        return await connectToKnownPeripheral(deviceID: deviceID, logPrefix: "BLE 重连")
    }

    /// 按设备 ID 建立连接（connect / reconnect 共用）。
    ///
    /// 关键修正：连接前先清掉本 central 对该外设的残留连接。
    /// bluetoothd 在设备物理链路仍存活时会拒绝新的连接请求
    /// （日志：Cannot connect device ... as it is already connected），
    /// 只回一个 connectionReady，应用侧拿不到可用的 GATT 通道，
    /// 导致重连看似"成功"却始终写不进命令。先 cancel 再 connect 可打破这个死结。
    private func connectToKnownPeripheral(deviceID: String, logPrefix: String) async -> Bool {
        guard let uuid = UUID(uuidString: deviceID) else {
            logger.error("\(logPrefix) 失败：无效的设备 ID \(deviceID)")
            return false
        }
        guard await waitForPoweredOn() else {
            logger.error("\(logPrefix)：蓝牙未就绪，放弃")
            return false
        }
        // 优先从系统缓存取，找不到则从当前已连接列表取
        // （设备被系统保持连接时只会出现在 retrieveConnectedPeripherals 里）。
        var peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first
        if peripheral == nil {
            peripheral = central.retrieveConnectedPeripherals(withServices: [uartServiceUUID])
                .first { $0.identifier.uuidString == deviceID }
        }
        guard let peripheral else {
            logger.log("\(logPrefix)：未找到设备 \(deviceID)")
            return false
        }
        peripheral.delegate = self
        // 清掉残留连接状态，避免撞上 "already connected" 而拿不到 GATT 通道。
        isReconnecting = true
        central.cancelPeripheralConnection(peripheral)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            scanContinuation = continuation
            connectedPeripheral = peripheral
            central.connect(peripheral, options: nil)
            // 超时兜底：CoreBluetooth 偶尔不回调 didConnect / didFailToConnect，
            // continuation 若永不 resume 会让上层重连循环永久静默。
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self.resumeScanIfPending(
                    false,
                    reason: "连接超时（\(logPrefix)）"
                )
            }
        }
    }

    public func send(_ command: SignalLightBLECommand) async -> Bool {
        guard let peripheral = connectedPeripheral,
              let characteristic = rxCharacteristic
        else {
            logger.log("BLE 未连接，丢弃命令 \(command.rawValue)")
            return false
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            writeContinuation = continuation
            peripheral.writeValue(command.payload, for: characteristic, type: .withResponse)
        }
    }

    public func disconnect() async {
        if central.isScanning {
            central.stopScan()
        }
        if let peripheral = connectedPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        rxCharacteristic = nil
    }

    public func setOnDisconnect(_ handler: @escaping @Sendable () async -> Void) {
        onDisconnectHandler = handler
    }

    public func waitForPoweredOn() async -> Bool {
        if central.state == .poweredOn { return true }
        // 最多等 3 秒（与 cpets 的 GUI 退化直连响应时间一致）。
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if central.state == .poweredOn { return true }
        }
        return false
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothSignalLightCommander: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            logger.log("BLE 蓝牙状态：\(String(describing: central.state.rawValue))")
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard peripheral.name?.hasPrefix(deviceNamePrefix) == true else { return }
        let device = SignalLightBLEDevice(
            id: peripheral.identifier.uuidString,
            name: peripheral.name
        )
        // 列表收集模式：去重追加，不停止扫描（由 scanForDevices 的 3 秒定时器停止）
        if scanListContinuation != nil {
            if !discoveredDevices.contains(where: { $0.id == device.id }) {
                discoveredDevices.append(device)
            }
            return
        }
        // scanAndConnect 模式：连第一台就停
        central.stopScan()
        peripheral.delegate = self
        connectedPeripheral = peripheral
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // 连接已建立，主动重连的抑制窗口到此结束。
        isReconnecting = false
        peripheral.discoverServices([uartServiceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.error("BLE 连接失败：\(error?.localizedDescription ?? "unknown")")
        connectedPeripheral = nil
        isReconnecting = false
        resumeScan(false)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.log("BLE 已断开：\(error?.localizedDescription ?? "normal")")
        // 身份校验：旧连接迟到的断连回调不得清空新连接已就绪的特征。
        // 若不校验，重连刚拿到的 rxCharacteristic 会被这条 stale 回调抹掉，
        // 使 commander 停在「connectedPeripheral 非空、rxCharacteristic 为 nil」的
        // 僵尸态：isConnected 为 false，重连守卫却因 connectedPeripheral 非空而假成功，
        // 所有命令被静默丢弃，只有给硬件断电重启才能恢复。
        guard peripheral === connectedPeripheral else {
            logger.log("BLE 忽略过期断连回调：\(peripheral.identifier.uuidString)")
            return
        }
        connectedPeripheral = nil
        rxCharacteristic = nil
        // 主动重连触发的断连：调用方本就在重连流程中，不再通知上层。
        if isReconnecting {
            isReconnecting = false
            return
        }
        // 通知上层 controller 启动重连流程（Issue #3）。
        // 用 Task 跳出 delegate 调用栈，避免回调中再次触发 CoreBluetooth 操作导致重入。
        if let onDisconnectHandler {
            Task { @MainActor in
                await onDisconnectHandler()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothSignalLightCommander: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            logger.error("BLE 发现服务失败：\(error.localizedDescription)")
            resumeScan(false)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == uartServiceUUID }) else {
            logger.error("BLE 未找到 Nordic UART Service")
            resumeScan(false)
            return
        }
        peripheral.discoverCharacteristics(
            [uartRXCharacteristicUUID, uartTXCharacteristicUUID],
            for: service
        )
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            logger.error("BLE 发现特征失败：\(error.localizedDescription)")
            resumeScan(false)
            return
        }
        guard let rx = service.characteristics?.first(where: { $0.uuid == uartRXCharacteristicUUID }) else {
            logger.error("BLE 未找到 RX 特征")
            resumeScan(false)
            return
        }
        rxCharacteristic = rx
        // 连接 + 特征就绪：记录设备 ID 供上层持久化（Issue #4）。
        lastConnectedDeviceIDValue = peripheral.identifier.uuidString
        resumeScan(true)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logger.error("BLE 写入失败：\(error.localizedDescription)")
        }
        resumeWrite(error == nil)
    }
}

// MARK: - 续体恢复（仅在 MainActor 调用）

extension CoreBluetoothSignalLightCommander {
    @MainActor
    private func resumeScan(_ success: Bool) {
        if let continuation = scanContinuation {
            scanContinuation = nil
            continuation.resume(returning: success)
        }
    }

    /// 超时兜底：只在 continuation 仍挂起时恢复，避免与正常回调重复 resume。
    @MainActor
    private func resumeScanIfPending(_ success: Bool, reason: String) {
        guard scanContinuation != nil else { return }
        logger.log("BLE \(reason)，按失败处理")
        connectedPeripheral = nil
        rxCharacteristic = nil
        isReconnecting = false
        resumeScan(success)
    }

    @MainActor
    private func resumeWrite(_ success: Bool) {
        if let continuation = writeContinuation {
            writeContinuation = nil
            continuation.resume(returning: success)
        }
    }
}
#endif
