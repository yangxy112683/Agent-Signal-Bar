import Foundation

// MARK: - 时钟协议（测试可注入，避免依赖真实 Task.sleep）

/// 蓝牙信号灯重连用的时钟抽象。
/// 生产实现用 `Foundation.Date()` + `Task.sleep`；
/// 测试用同步可推进的 fake，避免真实等待。
public protocol SignalLightBLEClock: Sendable {
    /// 当前时间（用于日志和调试，重连策略本身不依赖绝对时间）。
    func now() -> Date
    /// 异步等待指定秒数。测试实现可立即返回并记录等待时长。
    func sleep(seconds: TimeInterval) async
}

/// 生产实现：用 `Task.sleep` 真实等待。
public struct SystemSignalLightBLEClock: SignalLightBLEClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

// MARK: - 重连策略（纯函数，可测）

/// cpets `ble_worker.py` 重连策略的 Swift 版本：
/// - 前 5 次重试：每 2 秒一次（快速重试）
/// - 之后：每 30 秒一次（慢速轮询），无限重试
///
/// 这是纯计算函数，不接触真实 timer，测试直接断言输出。
public enum SignalLightBLEReconnectPolicy {
    /// 快速重试次数上限（达到后降级为慢速轮询）。
    public static let fastRetryLimit = 5
    /// 快速重试间隔（秒）。
    public static let fastInterval: TimeInterval = 2
    /// 慢速轮询间隔（秒）。
    public static let slowInterval: TimeInterval = 30

    /// 根据当前已重试次数返回下一次重连应等待的秒数。
    /// - 第 0..4 次（attempts < 5）：返回 2 秒
    /// - 第 5 次及之后（attempts >= 5）：返回 30 秒
    /// - 永不返回 nil（无限重试，直到连接成功或用户主动断开）
    public static func interval(forAttempt attempt: Int) -> TimeInterval {
        attempt < fastRetryLimit ? fastInterval : slowInterval
    }
}
