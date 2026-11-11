import Foundation
import XCTest
@testable import AgentSignalLight
@testable import AgentSignalLightCore

final class SignalLightBLEDebugTests: XCTestCase {
    private var usageOverrideURL: URL?

    override func setUp() {
        super.setUp()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-signal-ble-debug-usage-\(UUID().uuidString)",
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
    func testHardwareDebugCommandSendsOnEveryClick() async {
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
        radio.resetSentCommands()

        controller.pinHardwareDebug(.blinkYellow)
        await waitForBLETurn()
        controller.pinHardwareDebug(.blinkYellow)
        await waitForBLETurn()

        XCTAssertEqual(
            radio.sentCommands,
            [.blinkYellow, .blinkYellow],
            "double-click of the same debug button sends duplicate commands"
        )
    }

    @MainActor
    func testUnpinningHardwareDebugFlushesLiveSnapshot() async {
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

        controller.pinHardwareDebug(.blinkRed)
        await waitForBLETurn()
        radio.resetSentCommands()
        controller.resetOutboxForTesting()

        controller.setHardwareDebugPinned(false)
        await waitForBLETurn()

        XCTAssertFalse(controller.isHardwareDebugPinned)
        XCTAssertEqual(
            radio.sentCommands.last,
            SignalLightBLECommand.from(model.floatingSignalLightSnapshot.aggregate.displayState),
            "unpin force-flushes the floating snapshot command"
        )
    }

    @MainActor
    func testHardwareDebugIsIgnoredWhenBLEDisabled() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let radio = FakeSignalLightRadio()
        let model = makeMenuBarStatusModel(userDefaults: defaults)
        let controller = SignalLightBLEController(
            model: model,
            userDefaults: defaults,
            makeRadio: { radio },
            clock: FakeSignalLightBLEClock()
        )
        controller.activate()
        XCTAssertFalse(model.isSignalLightBLEEnabled)

        controller.pinHardwareDebug(.green)
        await waitForBLETurn()

        XCTAssertTrue(radio.sentCommands.isEmpty, "debug pin does not write while BLE is off")
        XCTAssertFalse(controller.isHardwareDebugPinned)
    }
}
