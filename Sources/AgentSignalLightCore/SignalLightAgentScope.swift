import Foundation

public enum SignalLightAgentScopeGroup: Int, CaseIterable, Hashable, Sendable {
    case codex
    case claude
    case other
}

public enum SignalLightAgentScope: String, CaseIterable, Hashable, Sendable {
    case codex
    case claude
    case codexDesktop = "codex-desktop"
    case codexCLI = "codex-cli"
    case codexVSCode = "codex-vscode"
    case codexXcode = "codex-xcode"
    case codexIDEA = "codex-idea"
    case claudeCode = "claude-code"
    case claudeDesktop = "claude-desktop"
    case localScript = "local-script"

    public static let selectableCases: [SignalLightAgentScope] = [
        .codexDesktop,
        .codexCLI,
        .codexVSCode,
        .codexXcode,
        .codexIDEA,
        .claudeCode,
        .localScript
    ]

    // NOTE: fork-specific — upstream (v1.5.0+) removed `.localScript` from
    // `visibleCases` to stop custom/generic hooks (e.g. codebuddy CLI) from
    // driving the signal light. We rely on that behavior, so it is
    // intentionally kept here. See `testManualLocalScriptSelectionDrivesVisibleSignalLight`.
    public static let visibleCases: [SignalLightAgentScope] = [
        .codexDesktop,
        .codexCLI,
        .codexVSCode,
        .codexXcode,
        .codexIDEA,
        .claudeCode,
        .localScript
    ]

    public static let allCases: [SignalLightAgentScope] = selectableCases

    public static let defaultSelectedCases: Set<SignalLightAgentScope> = [
        .codexDesktop,
        .codexCLI,
        .codexVSCode,
        .codexXcode,
        .codexIDEA
    ]

    public static let codexCases: Set<SignalLightAgentScope> = [
        .codexDesktop,
        .codexCLI,
        .codexVSCode,
        .codexXcode,
        .codexIDEA
    ]

    public static let claudeCases: Set<SignalLightAgentScope> = [
        .claudeCode
    ]

    public var group: SignalLightAgentScopeGroup {
        switch self {
        case .codex, .codexDesktop, .codexCLI, .codexVSCode, .codexXcode, .codexIDEA:
            return .codex
        case .claude, .claudeCode, .claudeDesktop:
            return .claude
        case .localScript:
            return .other
        }
    }

    public var sortOrder: Int {
        switch self {
        case .codexDesktop:
            return 0
        case .codexCLI:
            return 1
        case .codexVSCode:
            return 2
        case .codexXcode:
            return 3
        case .codexIDEA:
            return 4
        case .claudeCode:
            return 5
        case .claudeDesktop:
            return 6
        case .localScript:
            return 7
        case .codex:
            return 100
        case .claude:
            return 101
        }
    }

    public var expandedSelection: Set<SignalLightAgentScope> {
        switch self {
        case .codex:
            return Self.codexCases
        case .claude:
            return Self.claudeCases
        default:
            return Self.selectableCases.contains(self) ? [self] : []
        }
    }

    public func matches(session: SessionStatus) -> Bool {
        matches(
            sourceKey: ActivityPresentation.activitySourceKey(for: session),
            agent: session.agent,
            sessionID: session.sessionID
        )
    }

    public func matches(event: RecentSignalEvent) -> Bool {
        matches(
            sourceKey: ActivityPresentation.activitySourceKey(for: event),
            agent: event.agent,
            sessionID: event.sessionID
        )
    }

    private func matches(sourceKey: String, agent: String?, sessionID: String) -> Bool {
        let normalizedAgent = Self.normalizedAgentName(agent)
        let normalizedSessionID = sessionID.lowercased()

        switch self {
        case .codex:
            return sourceKey.hasPrefix("codex:")
        case .claude:
            return sourceKey.hasPrefix("claude:")
        case .codexDesktop:
            return sourceKey == "codex:desktop"
                || normalizedAgent == "codex-desktop"
                || normalizedSessionID.hasPrefix("codex-desktop:")
        case .codexCLI:
            return sourceKey == "codex:terminal"
                || normalizedAgent == "codex-cli"
                || normalizedAgent == "codex-terminal"
                || normalizedSessionID.hasPrefix("codex-cli:")
        case .codexVSCode:
            return sourceKey == "codex:ide:vs-code"
                || normalizedAgent == "codex-vscode"
                || normalizedAgent == "vscode-codex"
                || normalizedSessionID.hasPrefix("codex-vscode:")
        case .codexXcode:
            return sourceKey == "codex:ide:xcode"
                || normalizedAgent == "codex-xcode"
                || normalizedAgent == "xcode-codex"
                || normalizedSessionID.hasPrefix("codex-xcode:")
        case .codexIDEA:
            return sourceKey == "codex:ide:idea"
                || sourceKey == "codex:ide:jetbrains"
                || normalizedAgent == "codex-idea"
                || normalizedAgent == "codex-intellij"
                || normalizedAgent == "codex-jetbrains"
                || normalizedSessionID.hasPrefix("codex-idea:")
        case .claudeCode:
            return sourceKey == "claude:terminal"
                || sourceKey == "claude:desktop"
                || normalizedAgent == "claude-code"
                || normalizedAgent == "claude-cli"
                || normalizedAgent == "claude-desktop"
                || normalizedSessionID.hasPrefix("claude-code:")
                || normalizedSessionID.hasPrefix("claude-cli:")
                || normalizedSessionID.hasPrefix("claude-desktop:")
        case .claudeDesktop:
            return sourceKey == "claude:desktop"
                || normalizedAgent == "claude-desktop"
                || normalizedSessionID.hasPrefix("claude-desktop:")
        case .localScript:
            // NOTE: fork-specific — `.localScript` now drives the visible
            // signal light (see `visibleCases` above), so this match must
            // exclude `GenericHookAdapter.agentName`'s fallback sentinel
            // ("agent", returned when a generic hook payload omits an
            // explicit agent field). Otherwise unlabeled generic-hook noise
            // would be treated as a real active agent and drive the light.
            return !sourceKey.hasPrefix("codex:")
                && !sourceKey.hasPrefix("claude:")
                && !normalizedAgent.isEmpty
                && normalizedAgent != "agent"
        }
    }

    private static func normalizedAgentName(_ agent: String?) -> String {
        guard let agent else { return "" }
        return agent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }
}

public enum SignalLightAgentSelectionMode: String, Hashable, Sendable {
    case following
    case manual
}
