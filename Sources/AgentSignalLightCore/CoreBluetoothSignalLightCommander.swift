import Foundation
import os.log

#if os(macOS)
import CoreBluetooth

@MainActor
package final class CoreBluetoothSignalLightCommander: NSObject {
    private let deviceNamePrefix = "coding-"
    private let uartServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let uartRXCharacteristicUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let uartTXCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    private let logger = Logger(subsystem: "com.agent-signal-bar", category: "BLE")
    private let central: CBCentralManager
    private let scanDuration: TimeInterval

    private var connectedPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var scanContinuation: CheckedContinuation<SignalLightBLEDevice?, Never>?
    private var writeContinuation: CheckedContinuation<Bool, Never>?
    private var scanListContinuation: CheckedContinuation<[SignalLightBLEDevice], Never>?
    private var discoveredDevices: [SignalLightBLEDevice] = []
    private var onUnexpectedDisconnect: (@Sendable () async -> Void)?
    // cancel-then-connect fires didDisconnect; swallow that callback so the hunt
    // loop does not start a second reconnect on top of the one already running.
    private var isReconnecting = false

    package init(scanDuration: TimeInterval = 5.0) {
        self.scanDuration = scanDuration
        central = CBCentralManager(delegate: nil, queue: .main)
        super.init()
        central.delegate = self
    }

    private var currentDevice: SignalLightBLEDevice? {
        guard let peripheral = connectedPeripheral else { return nil }
        return makeDevice(from: peripheral)
    }

    private func makeDevice(from peripheral: CBPeripheral) -> SignalLightBLEDevice? {
        guard let id = SignalLightBLEDevice.ID(peripheral.identifier.uuidString) else { return nil }
        return SignalLightBLEDevice(id: id, name: peripheral.name ?? deviceNamePrefix)
    }
}

extension CoreBluetoothSignalLightCommander: @preconcurrency SignalLightBLECommanding {
    package var isReadyToWrite: Bool {
        connectedPeripheral != nil && rxCharacteristic != nil
    }

    package var connectedDeviceName: String? {
        connectedPeripheral?.name
    }

    package func scanAndConnectFirst() async -> SignalLightBLEDevice? {
        if isReadyToWrite { return currentDevice }
        guard await waitForPoweredOn() else {
            logger.error("BLE 蓝牙未就绪，放弃扫描")
            return nil
        }
        if isReadyToWrite { return currentDevice }
        return await withCheckedContinuation { (continuation: CheckedContinuation<SignalLightBLEDevice?, Never>) in
            scanContinuation = continuation
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    package func scanForDevices() async -> [SignalLightBLEDevice] {
        guard await waitForPoweredOn() else {
            logger.error("BLE 蓝牙未就绪，放弃扫描设备列表")
            return []
        }
        return await withCheckedContinuation { continuation in
            scanListContinuation = continuation
            discoveredDevices = []
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
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
    }

    package func connect(to deviceID: SignalLightBLEDevice.ID) async -> SignalLightBLEDevice? {
        if isReadyToWrite,
           let connected = connectedPeripheral,
           connected.identifier.uuidString == deviceID.rawValue {
            return currentDevice
        }
        return await connectToKnownPeripheral(deviceID: deviceID, logPrefix: "BLE connect")
    }

    package func reconnect(to deviceID: SignalLightBLEDevice.ID) async -> SignalLightBLEDevice? {
        if isReadyToWrite { return currentDevice }
        return await connectToKnownPeripheral(deviceID: deviceID, logPrefix: "BLE 重连")
    }

    // bluetoothd rejects a new connect while it still thinks the peripheral is
    // linked, returning connectionReady without GATT. Cancel first, then connect.
    private func connectToKnownPeripheral(
        deviceID: SignalLightBLEDevice.ID,
        logPrefix: String
    ) async -> SignalLightBLEDevice? {
        guard let uuid = UUID(uuidString: deviceID.rawValue) else {
            logger.error("\(logPrefix) 失败：无效的设备 ID \(deviceID.rawValue)")
            return nil
        }
        guard await waitForPoweredOn() else {
            logger.error("\(logPrefix)：蓝牙未就绪，放弃")
            return nil
        }
        var peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first
        if peripheral == nil {
            peripheral = central.retrieveConnectedPeripherals(withServices: [uartServiceUUID])
                .first { $0.identifier.uuidString == deviceID.rawValue }
        }
        guard let peripheral else {
            logger.log("\(logPrefix)：未找到设备 \(deviceID.rawValue)")
            return nil
        }
        peripheral.delegate = self
        isReconnecting = true
        central.cancelPeripheralConnection(peripheral)
        return await withCheckedContinuation { (continuation: CheckedContinuation<SignalLightBLEDevice?, Never>) in
            scanContinuation = continuation
            connectedPeripheral = peripheral
            central.connect(peripheral, options: nil)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self.resumeScanIfPending(nil, reason: "连接超时（\(logPrefix)）")
            }
        }
    }

    package func send(_ command: SignalLightBLECommand) async -> Bool {
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

    package func disconnect() async {
        if central.isScanning {
            central.stopScan()
        }
        if let peripheral = connectedPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        rxCharacteristic = nil
    }

    package func setOnUnexpectedDisconnect(_ handler: @escaping @Sendable () async -> Void) {
        onUnexpectedDisconnect = handler
    }

    private func waitForPoweredOn() async -> Bool {
        if central.state == .poweredOn { return true }
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if central.state == .poweredOn { return true }
        }
        return false
    }
}

extension CoreBluetoothSignalLightCommander: @preconcurrency CBCentralManagerDelegate {
    package func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            logger.log("BLE 蓝牙状态：\(String(describing: central.state.rawValue))")
        }
    }

    package func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard peripheral.name?.hasPrefix(deviceNamePrefix) == true,
              let device = makeDevice(from: peripheral)
        else { return }
        if scanListContinuation != nil {
            if !discoveredDevices.contains(where: { $0.id == device.id }) {
                discoveredDevices.append(device)
            }
            return
        }
        central.stopScan()
        peripheral.delegate = self
        connectedPeripheral = peripheral
        central.connect(peripheral, options: nil)
    }

    package func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isReconnecting = false
        peripheral.discoverServices([uartServiceUUID])
    }

    package func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        logger.error("BLE 连接失败：\(error?.localizedDescription ?? "unknown")")
        connectedPeripheral = nil
        isReconnecting = false
        resumeScan(nil)
    }

    package func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        logger.log("BLE 已断开：\(error?.localizedDescription ?? "normal")")
        // A stale didDisconnect from a previous peripheral must not wipe RX on
        // the current one. That leaves connectedPeripheral set and RX nil, so
        // isReadyToWrite is false while reconnect thinks a link still exists.
        guard peripheral === connectedPeripheral else {
            logger.log("BLE 忽略过期断连回调：\(peripheral.identifier.uuidString)")
            return
        }
        connectedPeripheral = nil
        rxCharacteristic = nil
        if isReconnecting {
            isReconnecting = false
            return
        }
        if let onUnexpectedDisconnect {
            Task { @MainActor in
                await onUnexpectedDisconnect()
            }
        }
    }
}

extension CoreBluetoothSignalLightCommander: @preconcurrency CBPeripheralDelegate {
    package func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            logger.error("BLE 发现服务失败：\(error.localizedDescription)")
            resumeScan(nil)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == uartServiceUUID }) else {
            logger.error("BLE 未找到 Nordic UART Service")
            resumeScan(nil)
            return
        }
        peripheral.discoverCharacteristics(
            [uartRXCharacteristicUUID, uartTXCharacteristicUUID],
            for: service
        )
    }

    package func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            logger.error("BLE 发现特征失败：\(error.localizedDescription)")
            resumeScan(nil)
            return
        }
        guard let rx = service.characteristics?.first(where: { $0.uuid == uartRXCharacteristicUUID }) else {
            logger.error("BLE 未找到 RX 特征")
            resumeScan(nil)
            return
        }
        rxCharacteristic = rx
        resumeScan(makeDevice(from: peripheral))
    }

    package func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            logger.error("BLE 写入失败：\(error.localizedDescription)")
        }
        resumeWrite(error == nil)
    }
}

extension CoreBluetoothSignalLightCommander {
    @MainActor
    private func resumeScan(_ device: SignalLightBLEDevice?) {
        if let continuation = scanContinuation {
            scanContinuation = nil
            continuation.resume(returning: device)
        }
    }

    @MainActor
    private func resumeScanIfPending(_ device: SignalLightBLEDevice?, reason: String) {
        guard scanContinuation != nil else { return }
        logger.log("BLE \(reason)，按失败处理")
        connectedPeripheral = nil
        rxCharacteristic = nil
        isReconnecting = false
        resumeScan(device)
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
