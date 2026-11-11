import Foundation

public protocol SignalLightBLEClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async
}

public struct SystemSignalLightBLEClock: SignalLightBLEClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

public enum SignalLightBLEReconnectPolicy {
    public static let fastRetryLimit = 5
    public static let fastInterval: TimeInterval = 2
    public static let slowInterval: TimeInterval = 30

    public static func interval(forAttempt attempt: Int) -> TimeInterval {
        attempt < fastRetryLimit ? fastInterval : slowInterval
    }
}
