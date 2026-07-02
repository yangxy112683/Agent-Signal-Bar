public enum ActiveSignalEffect: String, CaseIterable, Sendable {
    case greenBreathing = "green_breathing"
    case greenSteady = "green_steady"
    case greenSlowFlash = "green_slow_flash"
    case greenFastFlash = "green_fast_flash"
    case trafficCycle = "traffic_cycle"
}

public enum CompletedSignalEffect: String, CaseIterable, Sendable {
    case greenPulse = "green_pulse"
    case greenSteady = "green_steady"
    case yellowPulse = "yellow_pulse"
    case yellowSteady = "yellow_steady"
    case allSteady = "all_steady"
    case allPulse = "all_pulse"
}

public enum AlertSignalEffect: String, CaseIterable, Sendable {
    case pulse
    case steady
    case slowFlash = "slow_flash"
    case fastFlash = "fast_flash"
    case breathing
    case trafficCycle = "traffic_cycle"

    public static let allCases: [AlertSignalEffect] = [
        .breathing,
        .steady,
        .slowFlash,
        .fastFlash,
        .trafficCycle
    ]
}

public enum SignalEffectSpeed: String, CaseIterable, Sendable {
    case slow
    case standard
    case fast
}

public struct SignalEffectCustomization: Equatable, Sendable {
    public var thinkingEffect: ActiveSignalEffect
    public var activeEffect: ActiveSignalEffect
    public var activeSpeed: SignalEffectSpeed
    public var alertSpeed: SignalEffectSpeed
    public var completedEffect: CompletedSignalEffect
    public var needsReviewEffect: AlertSignalEffect
    public var permissionEffect: AlertSignalEffect
    public var blockedEffect: AlertSignalEffect

    public init(
        thinkingEffect: ActiveSignalEffect = .greenFastFlash,
        activeEffect: ActiveSignalEffect = .greenSlowFlash,
        activeSpeed: SignalEffectSpeed = .standard,
        alertSpeed: SignalEffectSpeed = .standard,
        completedEffect: CompletedSignalEffect = .greenSteady,
        needsReviewEffect: AlertSignalEffect = .slowFlash,
        permissionEffect: AlertSignalEffect = .slowFlash,
        blockedEffect: AlertSignalEffect = .fastFlash
    ) {
        self.thinkingEffect = thinkingEffect
        self.activeEffect = activeEffect
        self.activeSpeed = activeSpeed
        self.alertSpeed = alertSpeed
        self.completedEffect = completedEffect
        self.needsReviewEffect = needsReviewEffect
        self.permissionEffect = permissionEffect
        self.blockedEffect = blockedEffect
    }

    public static let `default` = SignalEffectCustomization()
}
