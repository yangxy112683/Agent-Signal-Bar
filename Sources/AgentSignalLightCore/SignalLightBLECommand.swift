import Foundation

public enum SignalLightBLECommand: String, Sendable, CaseIterable {
    case green = "GREEN"
    case blinkYellow = "BLINK_YELLOW"
    case blinkRed = "BLINK_RED"
    case off = "OFF"

    public var payload: Data { Data("\(rawValue)\n".utf8) }

    public static func from(_ state: DisplayState) -> SignalLightBLECommand {
        switch state {
        case .ready, .active, .completed: return .green
        case .needsReview, .stale: return .blinkYellow
        case .permission, .blocked: return .blinkRed
        case .paused: return .off
        }
    }
}
