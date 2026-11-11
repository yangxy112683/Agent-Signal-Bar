import Foundation
import XCTest
@testable import AgentSignalLightCore

final class SignalLightBLEProtocolTests: XCTestCase {
    func testCommandFromDisplayStateMapsReadyActiveCompletedToGreen() {
        XCTAssertEqual(SignalLightBLECommand.from(.ready), .green)
        XCTAssertEqual(SignalLightBLECommand.from(.active), .green)
        XCTAssertEqual(SignalLightBLECommand.from(.completed), .green)
    }

    func testCommandFromDisplayStateMapsNeedsReviewAndStaleToBlinkYellow() {
        XCTAssertEqual(SignalLightBLECommand.from(.needsReview), .blinkYellow)
        XCTAssertEqual(SignalLightBLECommand.from(.stale), .blinkYellow)
    }

    func testCommandFromDisplayStateMapsPermissionAndBlockedToBlinkRed() {
        XCTAssertEqual(SignalLightBLECommand.from(.permission), .blinkRed)
        XCTAssertEqual(SignalLightBLECommand.from(.blocked), .blinkRed)
    }

    func testCommandFromDisplayStateMapsPausedToOff() {
        XCTAssertEqual(SignalLightBLECommand.from(.paused), .off)
    }

    func testCommandFromCoversEveryDisplayState() {
        for state in DisplayState.allCases {
            _ = SignalLightBLECommand.from(state)
        }
    }

    func testPayloadIsUppercaseASCIITerminatedWithNewline() {
        XCTAssertEqual(SignalLightBLECommand.green.payload, Data("GREEN\n".utf8))
        XCTAssertEqual(SignalLightBLECommand.blinkYellow.payload, Data("BLINK_YELLOW\n".utf8))
        XCTAssertEqual(SignalLightBLECommand.blinkRed.payload, Data("BLINK_RED\n".utf8))
        XCTAssertEqual(SignalLightBLECommand.off.payload, Data("OFF\n".utf8))
    }

    func testReconnectPolicyUsesFastIntervalForFirstFiveAttempts() {
        XCTAssertEqual(SignalLightBLEReconnectPolicy.interval(forAttempt: 0), 2)
        XCTAssertEqual(SignalLightBLEReconnectPolicy.interval(forAttempt: 1), 2)
        XCTAssertEqual(SignalLightBLEReconnectPolicy.interval(forAttempt: 2), 2)
        XCTAssertEqual(SignalLightBLEReconnectPolicy.interval(forAttempt: 3), 2)
        XCTAssertEqual(SignalLightBLEReconnectPolicy.interval(forAttempt: 4), 2)
    }

    func testReconnectPolicyFallsBackToSlowIntervalAfterFiveFastRetries() {
        XCTAssertEqual(SignalLightBLEReconnectPolicy.interval(forAttempt: 5), 30)
        XCTAssertEqual(SignalLightBLEReconnectPolicy.interval(forAttempt: 6), 30)
        XCTAssertEqual(SignalLightBLEReconnectPolicy.interval(forAttempt: 100), 30)
    }

    func testReconnectPolicyNeverReturnsZeroInterval() {
        for attempt in 0..<1000 {
            XCTAssertGreaterThan(
                SignalLightBLEReconnectPolicy.interval(forAttempt: attempt),
                0,
                "attempt \(attempt) must keep retrying"
            )
        }
    }
}
