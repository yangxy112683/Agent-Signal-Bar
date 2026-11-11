import Foundation
import XCTest
@testable import AgentSignalLight
@testable import AgentSignalLightCore

final class SignalLightBLEControllerTests: XCTestCase {
    private var usageOverrideURL: URL?

    override func setUp() {
        super.setUp()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-signal-ble-usage-\(UUID().uuidString)",
            isDirectory: true
        )
        usageOverrideURL = directory.appendingPathComponent("usage.json")
        CodexAccountUsageSnapshotStore.defaultFileURLOverride = usageOverrideURL
    }

    override func tearDown() {
        if CodexAccountUsageSnapshotStore.defaultFileURLOverride == usageOverrideURL {
            CodexAccountUsageSnapshotStore.defaultFileURLOverride = nil
        }
        if let directory = usageOverrideURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: directory)
        }
        usageOverrideURL = nil
        super.tearDown()
    }

    @MainActor
    func testEnableWithBondReconnectsWithoutScanning() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let deviceID = SignalLightBLEDevice.ID("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        SignalLightBLEBondStore(userDefaults: defaults).save(deviceID)
        let radio = FakeSignalLightRadio()
        radio.reconnectDevice = SignalLightBLEDevice(id: deviceID, name: "coding-desk")
        let model = makeMenuBarStatusModel(userDefaults: defaults)
        let controller = SignalLightBLEController(
            model: model,
            userDefaults: defaults,
            makeRadio: { radio },
            clock: FakeSignalLightBLEClock()
        )
        controller.activate()
        model.setSignalLightBLEEnabled(true)
        await waitForBLETurn()

        XCTAssertEqual(radio.reconnectCallCount, 1, "saved bond should reconnect")
        XCTAssertEqual(radio.scanAndConnectFirstCallCount, 0, "enable with bond must not scan")
    }

    @MainActor
    func testEnableWithoutBondStaysIdleAndDoesNotScan() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let radio = FakeSignalLightRadio()
        var radioBirths = 0
        let model = makeMenuBarStatusModel(userDefaults: defaults)
        let controller = SignalLightBLEController(
            model: model,
            userDefaults: defaults,
            makeRadio: {
                radioBirths += 1
                return radio
            },
            clock: FakeSignalLightBLEClock()
        )
        controller.activate()
        XCTAssertEqual(radioBirths, 0, "radio stays lazy until enable")

        model.setSignalLightBLEEnabled(true)
        await waitForBLETurn()

        XCTAssertEqual(radioBirths, 1, "first enable births the radio")
        XCTAssertEqual(radio.scanAndConnectFirstCallCount, 0, "no bond must not hunt")
        XCTAssertEqual(radio.reconnectCallCount, 0)
        XCTAssertEqual(controller.connectionState, .idle)
    }

    @MainActor
    func testControllerReconnectStopsOnUserInitiatedDisconnect() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let deviceID = SignalLightBLEDevice.ID("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        SignalLightBLEBondStore(userDefaults: defaults).save(deviceID)
        let radio = FakeSignalLightRadio()
        radio.reconnectDevice = nil
        radio.scanAndConnectFirstDevice = nil
        let model = makeMenuBarStatusModel(userDefaults: defaults)
        let controller = SignalLightBLEController(
            model: model,
            userDefaults: defaults,
            makeRadio: { radio },
            clock: FakeSignalLightBLEClock()
        )
        controller.activate()
        model.setSignalLightBLEEnabled(true)
        await waitForBLETurn()

        let countAfterReconnect = radio.scanAndConnectFirstCallCount
        model.setSignalLightBLEEnabled(false)
        await waitForBLETurn()

        XCTAssertLessThanOrEqual(
            radio.scanAndConnectFirstCallCount - countAfterReconnect,
            2,
            "user disconnect must stop the hunt"
        )
    }

    @MainActor
    func testConcurrentScansShareOneInFlightTask() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let radio = FakeSignalLightRadio()
        radio.scanDelayNanoseconds = 80_000_000
        radio.discoveredDevices = [
            SignalLightBLEDevice(
                id: SignalLightBLEDevice.ID("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                name: "coding-desk"
            )
        ]
        let model = makeMenuBarStatusModel(userDefaults: defaults)
        let controller = SignalLightBLEController(
            model: model,
            userDefaults: defaults,
            makeRadio: { radio },
            clock: FakeSignalLightBLEClock()
        )
        controller.activate()
        model.setSignalLightBLEEnabled(true)
        await waitForBLETurn()

        async let first = controller.scanForDevices()
        async let second = controller.scanForDevices()
        let results = await (first, second)

        XCTAssertEqual(radio.scanForDevicesCallCount, 1, "concurrent scans coalesce onto one radio scan")
        XCTAssertEqual(results.0.map(\.name), ["coding-desk"])
        XCTAssertEqual(results.1.map(\.name), ["coding-desk"])
    }

    @MainActor
    func testHardwareMatchesFloatingLightAfterNeedsReviewWhenScopedAgentsExcludeAttention() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let fixture = try makeTemporaryBLEStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let needsReviewAt = now.addingTimeInterval(-10)

        _ = try fixture.store.applySessionSignal(
            .notification,
            sessionID: "codebuddy:thread",
            agent: "codebuddy",
            lastEvent: "NeedsReview",
            updatedAt: needsReviewAt
        )
        _ = try fixture.store.applySessionSignal(
            .done,
            sessionID: "cursor:main",
            agent: "cursor",
            lastEvent: "ToolDone",
            updatedAt: now
        )

        let model = makeMenuBarStatusModel(userDefaults: defaults, store: fixture.store)
        model.setSignalLightAgentScopes([.codexDesktop])

        XCTAssertEqual(
            model.snapshot.aggregate.displayState,
            .needsReview,
            "raw snapshot still reflects codebuddy attention"
        )
        XCTAssertEqual(
            model.floatingSignalLightSnapshot.aggregate.displayState,
            .ready,
            "scoped floating light returns to idle green"
        )

        let deviceID = SignalLightBLEDevice.ID("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        SignalLightBLEBondStore(userDefaults: defaults).save(deviceID)
        let radio = FakeSignalLightRadio()
        radio.reconnectDevice = SignalLightBLEDevice(id: deviceID, name: "coding-desk")
        let controller = SignalLightBLEController(
            model: model,
            userDefaults: defaults,
            makeRadio: { radio },
            clock: FakeSignalLightBLEClock()
        )
        controller.activate()
        model.setSignalLightBLEEnabled(true)
        await waitForBLETurn(nanoseconds: 300_000_000)

        XCTAssertEqual(
            radio.sentCommands.last,
            .green,
            "hardware mirrors floatingSignalLightSnapshot, not snapshot.aggregate"
        )
    }

    @MainActor
    func testIdenticalLiveCommandIsNotRewritten() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let deviceID = SignalLightBLEDevice.ID("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        SignalLightBLEBondStore(userDefaults: defaults).save(deviceID)
        let radio = FakeSignalLightRadio()
        radio.reconnectDevice = SignalLightBLEDevice(id: deviceID, name: "coding-desk")
        let model = makeMenuBarStatusModel(userDefaults: defaults)
        let controller = SignalLightBLEController(
            model: model,
            userDefaults: defaults,
            makeRadio: { radio },
            clock: FakeSignalLightBLEClock()
        )
        controller.activate()
        model.setSignalLightBLEEnabled(true)
        await waitForBLETurn()
        let sentAfterConnect = radio.sentCommands.count

        model.objectWillChange.send()
        model.isMonitoringPaused = model.isMonitoringPaused
        await waitForBLETurn()

        XCTAssertEqual(
            radio.sentCommands.count,
            sentAfterConnect,
            "same live command is not rewritten"
        )
    }
}

@MainActor
func makeMenuBarStatusModel(
    userDefaults: UserDefaults,
    store: SignalStateStore = SignalStateStore()
) -> MenuBarStatusModel {
    MenuBarStatusModel(
        store: store,
        userDefaults: userDefaults,
        startsMonitoring: false
    )
}

func makeTemporaryBLEStore() throws -> (store: SignalStateStore, directory: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "agent-signal-ble-store-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = SignalStateStore(
        stateFileURL: directory.appendingPathComponent("status.json"),
        sessionTTLSeconds: 86_400,
        completedTTLSeconds: 86_400
    )
    return (store, directory)
}

@MainActor
func waitForBLETurn(nanoseconds: UInt64 = 150_000_000) async {
    await Task.yield()
    try? await Task.sleep(nanoseconds: nanoseconds)
}

final class FakeSignalLightBLEClock: SignalLightBLEClock, @unchecked Sendable {
    private var currentDate = Date()
    private(set) var slept: [TimeInterval] = []

    func now() -> Date { currentDate }

    func sleep(seconds: TimeInterval) async {
        slept.append(seconds)
        await Task.yield()
    }
}

final class FakeSignalLightRadio: SignalLightBLECommanding, @unchecked Sendable {
    private var ready = false
    private var name: String? = "coding-test"
    private var disconnectHandler: (@Sendable () async -> Void)?
    var reconnectDevice: SignalLightBLEDevice?
    var scanAndConnectFirstDevice: SignalLightBLEDevice?
    var connectDevice: SignalLightBLEDevice?
    var discoveredDevices: [SignalLightBLEDevice] = []
    var sendResult = true
    var scanDelayNanoseconds: UInt64 = 0
    private(set) var reconnectCallCount = 0
    private(set) var scanAndConnectFirstCallCount = 0
    private(set) var scanForDevicesCallCount = 0
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var sentCommands: [SignalLightBLECommand] = []

    var isReadyToWrite: Bool {
        get async { ready }
    }

    var connectedDeviceName: String? {
        get async { name }
    }

    func scanForDevices() async -> [SignalLightBLEDevice] {
        scanForDevicesCallCount += 1
        let devices = discoveredDevices
        if scanDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: scanDelayNanoseconds)
        }
        return devices
    }

    func connect(to deviceID: SignalLightBLEDevice.ID) async -> SignalLightBLEDevice? {
        connectCallCount += 1
        let device = connectDevice ?? SignalLightBLEDevice(id: deviceID, name: "coding-test")
        ready = true
        name = device.name
        return device
    }

    func reconnect(to deviceID: SignalLightBLEDevice.ID) async -> SignalLightBLEDevice? {
        reconnectCallCount += 1
        let device = reconnectDevice
        if let device {
            ready = true
            name = device.name
        }
        return device
    }

    func scanAndConnectFirst() async -> SignalLightBLEDevice? {
        scanAndConnectFirstCallCount += 1
        let device = scanAndConnectFirstDevice
        if let device {
            ready = true
            name = device.name
        }
        return device
    }

    func send(_ command: SignalLightBLECommand) async -> Bool {
        sentCommands.append(command)
        return sendResult && ready
    }

    func disconnect() async {
        disconnectCallCount += 1
        ready = false
    }

    func setOnUnexpectedDisconnect(_ handler: @escaping @Sendable () async -> Void) {
        disconnectHandler = handler
    }

    func resetSentCommands() {
        sentCommands = []
    }

    func simulateDisconnect() async {
        ready = false
        if let disconnectHandler {
            await disconnectHandler()
        }
    }
}
