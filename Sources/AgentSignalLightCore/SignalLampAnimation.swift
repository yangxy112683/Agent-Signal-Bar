public enum SignalLampColor: CaseIterable, Sendable {
    case red
    case yellow
    case green
}

public enum SignalLampAnimation {
    public static func intensity(
        _ color: SignalLampColor,
        signal: AgentSignal,
        tick: Int,
        allLightsOn: Bool = false,
        customization: SignalEffectCustomization = .default
    ) -> Double {
        if allLightsOn {
            return 1
        }

        switch signal.displayState {
        case .ready:
            return color == .green ? 1 : 0
        case .active:
            return activeIntensity(color, signal: signal, tick: tick, customization: customization)
        case .completed:
            return completedIntensity(color, tick: tick, customization: customization)
        case .needsReview:
            return alertIntensity(
                color,
                expectedColor: .yellow,
                tick: tick,
                speed: customization.alertSpeed,
                effect: customization.needsReviewEffect
            )
        case .permission:
            return alertIntensity(
                color,
                expectedColor: .red,
                tick: tick,
                speed: customization.alertSpeed,
                effect: customization.permissionEffect
            )
        case .blocked:
            return alertIntensity(
                color,
                expectedColor: .red,
                tick: tick,
                speed: customization.alertSpeed,
                effect: customization.blockedEffect
            )
        case .stale:
            guard color == .yellow else { return 0 }
            let values: [Double] = [0.35, 0.5, 0.65, 0.5, 0, 0, 0, 0]
            return values[adjustedTick(tick, speed: customization.alertSpeed) % values.count]
        case .paused:
            return 0
        }
    }

    public static func scale(
        _ color: SignalLampColor,
        signal: AgentSignal,
        tick: Int,
        allLightsOn: Bool = false,
        customization: SignalEffectCustomization = .default
    ) -> Double {
        let intensity = intensity(
            color,
            signal: signal,
            tick: tick,
            allLightsOn: allLightsOn,
            customization: customization
        )
        guard intensity > 0 else {
            return 1
        }

        switch signal.displayState {
        case .active, .completed, .needsReview, .permission, .blocked, .stale:
            return 0.48 + intensity * 0.52
        case .ready, .paused:
            return 1
        }
    }

    public static func isLit(
        _ color: SignalLampColor,
        signal: AgentSignal,
        tick: Int,
        allLightsOn: Bool = false,
        customization: SignalEffectCustomization = .default
    ) -> Bool {
        intensity(
            color,
            signal: signal,
            tick: tick,
            allLightsOn: allLightsOn,
            customization: customization
        ) > 0
    }

    /// Hardware command for the same look the software lamps render.
    /// Hardware only has GREEN, BLINK_YELLOW, BLINK_RED, and OFF.
    /// Green flash, breathe, and pulse collapse to GREEN. Yellow and red stay on the blink commands because the hardware has no steady yellow or red.
    public static func hardwareCommand(
        signal: AgentSignal,
        tick: Int,
        allLightsOn: Bool = false,
        customization: SignalEffectCustomization = .default
    ) -> SignalLightBLECommand {
        switch signal.displayState {
        case .paused:
            return .off
        case .ready:
            return .green
        case .active:
            if allLightsOn {
                return .green
            }
            let effect = signal == .thinking ? customization.thinkingEffect : customization.activeEffect
            return hardwareCommand(forActive: effect, tick: tick, speed: customization.activeSpeed)
        case .completed:
            if allLightsOn {
                return .green
            }
            return hardwareCommand(forCompleted: customization.completedEffect)
        case .needsReview:
            return hardwareCommand(
                forAlert: customization.needsReviewEffect,
                color: .yellow,
                tick: tick,
                speed: customization.alertSpeed
            )
        case .permission:
            return hardwareCommand(
                forAlert: customization.permissionEffect,
                color: .red,
                tick: tick,
                speed: customization.alertSpeed
            )
        case .blocked:
            return hardwareCommand(
                forAlert: customization.blockedEffect,
                color: .red,
                tick: tick,
                speed: customization.alertSpeed
            )
        case .stale:
            return .blinkYellow
        }
    }

    private static func activeIntensity(
        _ color: SignalLampColor,
        signal: AgentSignal,
        tick: Int,
        customization: SignalEffectCustomization
    ) -> Double {
        let activeTick = adjustedTick(tick, speed: customization.activeSpeed)
        let activeEffect = signal == .thinking ? customization.thinkingEffect : customization.activeEffect

        switch activeEffect {
        case .greenBreathing:
            guard color == .green else { return 0 }
            let values: [Double] = [0.35, 0.42, 0.52, 0.66, 0.82, 1.0, 0.82, 0.66, 0.52, 0.42]
            return values[activeTick % values.count]
        case .greenSteady:
            return color == .green ? 1 : 0
        case .greenSlowFlash:
            guard color == .green else { return 0 }
            let values: [Double] = [1, 1, 1, 0, 0, 0]
            return values[activeTick % values.count]
        case .greenFastFlash:
            guard color == .green else { return 0 }
            let values: [Double] = [1, 0]
            return values[activeTick % values.count]
        case .trafficCycle:
            let phaseColors: [SignalLampColor] = [.red, .yellow, .green]
            let ticksPerColor = 4
            let phase = (activeTick / ticksPerColor) % phaseColors.count
            guard color == phaseColors[phase] else { return 0 }
            return 1
        }
    }

    private static func alertIntensity(
        _ color: SignalLampColor,
        expectedColor: SignalLampColor,
        tick: Int,
        speed: SignalEffectSpeed,
        effect: AlertSignalEffect
    ) -> Double {
        if effect != .trafficCycle {
            guard color == expectedColor else { return 0 }
        }

        let alertTick = adjustedTick(tick, speed: speed)
        switch effect {
        case .pulse:
            let values: [Double] = [0.45, 0.72, 1.0, 0.72, 0, 0, 0, 0]
            return values[alertTick % values.count]
        case .steady:
            return 1
        case .slowFlash:
            let values: [Double] = [1, 1, 1, 0, 0, 0]
            return values[alertTick % values.count]
        case .fastFlash:
            let values: [Double] = [1, 0]
            return values[alertTick % values.count]
        case .breathing:
            let values: [Double] = [0.35, 0.42, 0.52, 0.66, 0.82, 1.0, 0.82, 0.66, 0.52, 0.42]
            return values[alertTick % values.count]
        case .trafficCycle:
            let phaseColors: [SignalLampColor] = [.red, .yellow, .green]
            let ticksPerColor = 4
            let phase = (alertTick / ticksPerColor) % phaseColors.count
            guard color == phaseColors[phase] else { return 0 }
            return 1
        }
    }

    private static func completedIntensity(
        _ color: SignalLampColor,
        tick: Int,
        customization: SignalEffectCustomization
    ) -> Double {
        let completedTick = adjustedTick(tick, speed: customization.alertSpeed)
        let pulseValues: [Double] = [1.0, 0.7, 0, 0]

        switch customization.completedEffect {
        case .greenPulse:
            guard color == .green else { return 0 }
            return pulseValues[completedTick % pulseValues.count]
        case .greenSteady:
            return color == .green ? 1 : 0
        case .yellowPulse:
            guard color == .yellow else { return 0 }
            return pulseValues[completedTick % pulseValues.count]
        case .yellowSteady:
            return color == .yellow ? 1 : 0
        case .allSteady:
            return 1
        case .allPulse:
            return pulseValues[completedTick % pulseValues.count]
        }
    }

    private static func hardwareCommand(
        forActive effect: ActiveSignalEffect,
        tick: Int,
        speed: SignalEffectSpeed
    ) -> SignalLightBLECommand {
        switch effect {
        case .greenBreathing, .greenSteady, .greenSlowFlash, .greenFastFlash:
            return .green
        case .trafficCycle:
            return trafficCycleCommand(tick: tick, speed: speed)
        }
    }

    private static func hardwareCommand(forCompleted effect: CompletedSignalEffect) -> SignalLightBLECommand {
        switch effect {
        case .greenPulse, .greenSteady, .allSteady, .allPulse:
            return .green
        case .yellowPulse, .yellowSteady:
            return .blinkYellow
        }
    }

    private static func hardwareCommand(
        forAlert effect: AlertSignalEffect,
        color: SignalLampColor,
        tick: Int,
        speed: SignalEffectSpeed
    ) -> SignalLightBLECommand {
        if effect == .trafficCycle {
            return trafficCycleCommand(tick: tick, speed: speed)
        }
        switch color {
        case .red:
            return .blinkRed
        case .yellow:
            return .blinkYellow
        case .green:
            return .green
        }
    }

    private static func trafficCycleCommand(tick: Int, speed: SignalEffectSpeed) -> SignalLightBLECommand {
        let phaseColors: [SignalLampColor] = [.red, .yellow, .green]
        let ticksPerColor = 4
        let phase = (adjustedTick(tick, speed: speed) / ticksPerColor) % phaseColors.count
        switch phaseColors[phase] {
        case .red:
            return .blinkRed
        case .yellow:
            return .blinkYellow
        case .green:
            return .green
        }
    }

    private static func adjustedTick(_ tick: Int, speed: SignalEffectSpeed) -> Int {
        let tick = normalizedTick(tick)
        switch speed {
        case .slow:
            return tick / 2
        case .standard:
            return tick
        case .fast:
            return tick * 2
        }
    }

    private static func normalizedTick(_ tick: Int) -> Int {
        tick >= 0 ? tick : 0
    }
}
