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
final class CoreBluetoothSignalLightCommander: NSObject {
    private let deviceNamePrefix = "coding-"
    private let uartServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let uartRXCharacteristicUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let uartTXCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    private let logger = Logger(subsystem: "com.agent-signal-bar", category: "BLE")
    private let central: CBCentralManager

    private var connectedPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var scanContinuation: CheckedContinuation<Bool, Never>?
    private var writeContinuation: CheckedContinuation<Bool, Never>?

    override init() {
        // 用 main queue 让 CoreBluetooth 的 delegate 回调直接在主线程执行，
        // 这样所有可变状态都可以安全地隔离在 MainActor 上，无需 Task 跳转。
        central = CBCentralManager(delegate: nil, queue: .main)
        super.init()
        central.delegate = self
    }
}

// MARK: - SignalLightBLECommanding

extension CoreBluetoothSignalLightCommander: SignalLightBLECommanding {
    var isConnected: Bool {
        connectedPeripheral != nil && rxCharacteristic != nil
    }

    func scanAndConnect() async -> Bool {
        // 已连接则直接成功。
        if connectedPeripheral != nil { return true }
        // 等待蓝牙权限就绪（poweredOn）。
        guard await waitForPoweredOn() else {
            logger.error("BLE 蓝牙未就绪，放弃扫描")
            return false
        }
        if connectedPeripheral != nil { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            scanContinuation = continuation
            central.scanForPeripherals(
                withServices: [uartServiceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    func send(_ command: SignalLightBLECommand) async -> Bool {
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

    func disconnect() async {
        if central.isScanning {
            central.stopScan()
        }
        if let peripheral = connectedPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        rxCharacteristic = nil
    }

    private func waitForPoweredOn() async -> Bool {
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
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            logger.log("BLE 蓝牙状态：\(String(describing: central.state.rawValue))")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard peripheral.name?.hasPrefix(deviceNamePrefix) == true else { return }
        central.stopScan()
        peripheral.delegate = self
        connectedPeripheral = peripheral
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([uartServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.error("BLE 连接失败：\(error?.localizedDescription ?? "unknown")")
        connectedPeripheral = nil
        resumeScan(false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.log("BLE 已断开：\(error?.localizedDescription ?? "normal")")
        connectedPeripheral = nil
        rxCharacteristic = nil
        // 断连不在这里自动重连（重连是 Issue #3 的范围）。
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothSignalLightCommander: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
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

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
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
        resumeScan(true)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
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

    @MainActor
    private func resumeWrite(_ success: Bool) {
        if let continuation = writeContinuation {
            writeContinuation = nil
            continuation.resume(returning: success)
        }
    }
}
#endif
