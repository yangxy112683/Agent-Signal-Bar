import Foundation

/// Derives the lamp / menu-bar intervention view from recorded state.
///
/// `agent-signal status --json` prints the store aggregate. This type is the
/// same pipeline as `MenuBarStatusModel.displaySnapshot`: Light Agent scopes,
/// recent-event fallback sessions, TTL windows, and the final `display_state`.
public enum InterventionDisplay {
    public static let appPreferencesSuiteName = "com.agentsignallight.AgentSignalLight"

    public static let recentActivityFallbackWindow: TimeInterval = 5 * 60
    public static let passiveActiveDisplayWindow: TimeInterval = 45
    public static let activeDisplayWindow: TimeInterval = 5 * 60
    public static let recentEventDeduplicationWindow: TimeInterval = 4

    public struct Preferences: Equatable, Sendable {
        public var selectionMode: SignalLightAgentSelectionMode
        public var scopes: Set<SignalLightAgentScope>
        public var isCodexDesktopMonitoringEnabled: Bool
        public var isClaudeDesktopMonitoringEnabled: Bool

        public init(
            selectionMode: SignalLightAgentSelectionMode,
            scopes: Set<SignalLightAgentScope>,
            isCodexDesktopMonitoringEnabled: Bool = true,
            isClaudeDesktopMonitoringEnabled: Bool = true
        ) {
            self.selectionMode = selectionMode
            self.scopes = scopes
            self.isCodexDesktopMonitoringEnabled = isCodexDesktopMonitoringEnabled
            self.isClaudeDesktopMonitoringEnabled = isClaudeDesktopMonitoringEnabled
        }

        public static func fromAppDefaults(
            _ defaults: UserDefaults = UserDefaults(suiteName: InterventionDisplay.appPreferencesSuiteName)
                ?? .standard
        ) -> Preferences {
            let storedScopes = defaults.stringArray(forKey: "signalLightAgentScopes")
            let legacyScope = defaults.string(forKey: "signalLightAgentScope")
            return Preferences(
                selectionMode: resolvedSelectionMode(
                    storedMode: defaults.string(forKey: "signalLightAgentSelectionMode"),
                    storedScopes: storedScopes,
                    legacyScope: legacyScope
                ),
                scopes: resolvedScopes(storedScopes: storedScopes, legacyScope: legacyScope),
                isCodexDesktopMonitoringEnabled:
                    defaults.object(forKey: "isCodexDesktopMonitoringEnabled") as? Bool ?? true,
                isClaudeDesktopMonitoringEnabled:
                    defaults.object(forKey: "isClaudeDesktopMonitoringEnabled") as? Bool ?? true
            )
        }
    }

    public struct Exclusion: Equatable, Sendable {
        public let sessionID: String
        public let agent: String?
        public let event: String?
        public let signal: AgentSignal
        public let updatedAt: Date
        public let reason: String

        public init(
            sessionID: String,
            agent: String?,
            event: String?,
            signal: AgentSignal,
            updatedAt: Date,
            reason: String
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.event = event
            self.signal = signal
            self.updatedAt = updatedAt
            self.reason = reason
        }
    }

    public struct Report: Equatable, Sendable {
        public let displaySnapshot: SignalSnapshot
        public let activitySnapshot: SignalSnapshot
        public let displayScopes: Set<SignalLightAgentScope>
        public let combinedSessions: [SessionStatus]
        public let fallbackSessions: [SessionStatus]
        public let exclusions: [Exclusion]
        public let presenceIncluded: Bool
        public let preferences: Preferences
        public let completedDisplayWindow: TimeInterval
        public let transientAlertDisplayWindow: TimeInterval
    }

    public static func resolvedScopes(
        storedScopes: [String]?,
        legacyScope: String?
    ) -> Set<SignalLightAgentScope> {
        let selectableScopes = Set(SignalLightAgentScope.selectableCases)
        let resolvedStoredScopes = Set(
            (storedScopes ?? [])
                .compactMap(SignalLightAgentScope.init(rawValue:))
                .flatMap(\.expandedSelection)
        )
        .intersection(selectableScopes)

        if !resolvedStoredScopes.isEmpty {
            return resolvedStoredScopes
        }

        if let legacyScope,
           let legacySelection = SignalLightAgentScope(rawValue: legacyScope) {
            let resolvedLegacyScopes = legacySelection.expandedSelection.intersection(selectableScopes)
            if !resolvedLegacyScopes.isEmpty {
                return resolvedLegacyScopes
            }
        }

        return SignalLightAgentScope.defaultSelectedCases
    }

    public static func resolvedSelectionMode(
        storedMode: String?,
        storedScopes: [String]?,
        legacyScope: String?
    ) -> SignalLightAgentSelectionMode {
        if let storedMode,
           let mode = SignalLightAgentSelectionMode(rawValue: storedMode) {
            return mode
        }

        if storedScopes != nil || legacyScope != nil {
            return .manual
        }

        return .following
    }

    public static func shouldUseRecentEventAsFallbackSession(
        _ event: RecentSignalEvent,
        now: Date,
        completedDisplayWindow: TimeInterval = 30,
        transientAlertDisplayWindow: TimeInterval = 30
    ) -> Bool {
        if ActivityPresentation.isManualIdleControlEvent(event) {
            return false
        }

        let age = now.timeIntervalSince(event.updatedAt)
        switch event.signal.displayState {
        case .active:
            return age <= recentActivityFallbackWindow(for: event)
        case .completed:
            return age <= completedDisplayWindow
        case .needsReview, .permission, .blocked, .stale:
            return age <= transientAlertDisplayWindow
        case .ready, .paused:
            return false
        }
    }

    public static func derive(
        recorded: SignalSnapshot,
        preferences: Preferences,
        presenceSessions: [SessionStatus] = [],
        now: Date = Date(),
        completedDisplayWindow: TimeInterval = 30,
        transientAlertDisplayWindow: TimeInterval = 30,
        presenceIncluded: Bool = false
    ) -> Report {
        var exclusions: [Exclusion] = []
        let visibleRecentEvents = recorded.recentEvents.filter { event in
            guard !isSignalTestEvent(event.event) else {
                exclusions.append(exclusion(for: event, reason: "signal_test"))
                return false
            }
            return true
        }
        let completionCutoffsBySourceKey = latestCompletionCutoffsBySourceKey(visibleRecentEvents)
        let resolvingCutoffsBySourceKey = latestResolvingCutoffsBySourceKey(visibleRecentEvents)

        var sessions = recorded.sessions.filter { session in
            if let reason = storedSessionExclusionReason(
                session,
                now: now,
                completedDisplayWindow: completedDisplayWindow,
                transientAlertDisplayWindow: transientAlertDisplayWindow
            ) {
                exclusions.append(exclusion(for: session, reason: reason))
                return false
            }
            if isSupersededByCompletedRecentEvent(
                session,
                completionCutoffsBySourceKey: completionCutoffsBySourceKey
            ) {
                exclusions.append(exclusion(for: session, reason: "superseded_by_completed"))
                return false
            }
            if isSupersededByResolvingRecentEvent(
                session,
                resolvingCutoffsBySourceKey: resolvingCutoffsBySourceKey
            ) {
                exclusions.append(exclusion(for: session, reason: "superseded_by_resolving"))
                return false
            }
            return true
        }

        let fallbackSessions = recentActivityFallbackSessions(
            from: visibleRecentEvents,
            existingSessions: sessions,
            completionCutoffsBySourceKey: completionCutoffsBySourceKey,
            resolvingCutoffsBySourceKey: resolvingCutoffsBySourceKey,
            now: now,
            completedDisplayWindow: completedDisplayWindow,
            transientAlertDisplayWindow: transientAlertDisplayWindow,
            exclusions: &exclusions
        )
        sessions.append(contentsOf: fallbackSessions)

        let liveAgentKeys = Set(
            sessions.compactMap { session -> String? in
                guard shouldSuppressDesktopPresence(
                    for: session,
                    now: now,
                    transientAlertDisplayWindow: transientAlertDisplayWindow
                ) else { return nil }
                return ActivityPresentation.activitySourceKey(for: session)
            }
        )

        let filteredPresence = presenceSessions.filter { session in
            let sourceKey = ActivityPresentation.activitySourceKey(for: session)
            if sourceKey.hasPrefix("codex:") {
                return preferences.isCodexDesktopMonitoringEnabled
            }
            if sourceKey.hasPrefix("claude:") {
                return preferences.isClaudeDesktopMonitoringEnabled
            }
            return true
        }

        for desktopSession in filteredPresence {
            let sourceKey = ActivityPresentation.activitySourceKey(for: desktopSession)
            guard !liveAgentKeys.contains(sourceKey) else { continue }
            sessions.append(desktopSession)
        }

        let combinedSessions = sessions.sorted(by: displaySessionSortPrecedes)
        let displayScopes = scopesForDisplay(
            from: combinedSessions,
            preferences: preferences
        )
        let scopedDisplaySessions = combinedSessions.filter { Self.session($0, matches: displayScopes) }
        let lampSessions = deduplicatedDisplaySessions(scopedDisplaySessions)
        let scopedRecentEvents = recorded.recentEvents
            .filter { !isSignalTestEvent($0.event) }
            .filter { Self.event($0, matches: displayScopes) }
        let displayUpdatedAt = lampSessions.map(\.updatedAt).max()
        let displaySnapshot = SignalSnapshot(
            aggregate: aggregateForSignalLightScopes(
                sessions: lampSessions,
                fallback: recorded.aggregate,
                scopes: displayScopes,
                selectionMode: preferences.selectionMode
            ),
            sessions: lampSessions,
            recentEvents: deduplicatedRecentEvents(scopedRecentEvents),
            stateFileURL: recorded.stateFileURL,
            updatedAt: displayUpdatedAt
        )

        let activitySessions = Self.deduplicatedDisplaySessions(combinedSessions)
        let activitySnapshot = SignalSnapshot(
            aggregate: aggregateForSessions(activitySessions, fallback: recorded.aggregate),
            sessions: activitySessions,
            recentEvents: deduplicatedRecentEvents(
                recorded.recentEvents.filter { !isSignalTestEvent($0.event) }
            ),
            stateFileURL: recorded.stateFileURL,
            updatedAt: activitySessions.map(\.updatedAt).max() ?? recorded.updatedAt
        )

        return Report(
            displaySnapshot: displaySnapshot,
            activitySnapshot: activitySnapshot,
            displayScopes: displayScopes,
            combinedSessions: combinedSessions,
            fallbackSessions: fallbackSessions,
            exclusions: exclusions,
            presenceIncluded: presenceIncluded,
            preferences: preferences,
            completedDisplayWindow: completedDisplayWindow,
            transientAlertDisplayWindow: transientAlertDisplayWindow
        )
    }

    private static func recentActivityFallbackSessions(
        from recentEvents: [RecentSignalEvent],
        existingSessions: [SessionStatus],
        completionCutoffsBySourceKey: [String: Date],
        resolvingCutoffsBySourceKey: [String: Date],
        now: Date,
        completedDisplayWindow: TimeInterval,
        transientAlertDisplayWindow: TimeInterval,
        exclusions: inout [Exclusion]
    ) -> [SessionStatus] {
        let latestExistingSessionBySourceKey = Dictionary(
            grouping: existingSessions,
            by: ActivityPresentation.activitySourceKey(for:)
        ).compactMapValues { sessions in
            sessions.max(by: { lhs, rhs in lhs.updatedAt < rhs.updatedAt })
        }
        var handledSourceKeys: Set<String> = []
        var fallbackSessions: [SessionStatus] = []

        for event in recentEvents.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let sourceKey = ActivityPresentation.activitySourceKey(for: event)
            if handledSourceKeys.contains(sourceKey) {
                appendFallbackExclusion(for: event, reason: "duplicate_source", into: &exclusions)
                continue
            }

            if let existingSession = latestExistingSessionBySourceKey[sourceKey],
               existingSession.updatedAt >= event.updatedAt,
               !ActivityPresentation.isPresenceSession(existingSession) {
                appendFallbackExclusion(for: event, reason: "superseded_by_session", into: &exclusions)
                continue
            }

            if isSupersededByCompletedRecentEvent(
                event,
                completionCutoffsBySourceKey: completionCutoffsBySourceKey
            ) {
                appendFallbackExclusion(for: event, reason: "superseded_by_completed", into: &exclusions)
                continue
            }

            if isSupersededByResolvingRecentEvent(
                event,
                resolvingCutoffsBySourceKey: resolvingCutoffsBySourceKey
            ) {
                appendFallbackExclusion(for: event, reason: "superseded_by_resolving", into: &exclusions)
                continue
            }

            guard shouldUseRecentEventAsFallbackSession(
                event,
                now: now,
                completedDisplayWindow: completedDisplayWindow,
                transientAlertDisplayWindow: transientAlertDisplayWindow
            ) else {
                appendFallbackExclusion(
                    for: event,
                    reason: fallbackRejectionReason(event),
                    into: &exclusions
                )
                continue
            }

            handledSourceKeys.insert(sourceKey)
            fallbackSessions.append(
                SessionStatus(
                    sessionID: "recent-activity:\(sourceKey)",
                    signal: event.signal,
                    updatedAt: event.updatedAt,
                    agent: event.agent,
                    lastEvent: event.event
                )
            )
        }

        return fallbackSessions
    }

    private static func scopesForDisplay(
        from displaySessions: [SessionStatus],
        preferences: Preferences
    ) -> Set<SignalLightAgentScope> {
        switch preferences.selectionMode {
        case .manual:
            return preferences.scopes.intersection(Set(SignalLightAgentScope.visibleCases))
        case .following:
            guard let scope = followedScope(in: displaySessions) else {
                return []
            }
            return [scope]
        }
    }

    private static func followedScope(in displaySessions: [SessionStatus]) -> SignalLightAgentScope? {
        struct Candidate {
            let scope: SignalLightAgentScope
            let priority: Int
            let updatedAt: Date
        }

        let candidates = SignalLightAgentScope.visibleCases.compactMap { scope -> Candidate? in
            let matchingSessions = displaySessions.filter {
                scope.matches(session: $0) && isFollowCandidateSession($0)
            }

            guard let bestSession = matchingSessions.max(by: { lhs, rhs in
                if lhs.signal.displayState.priority != rhs.signal.displayState.priority {
                    return lhs.signal.displayState.priority < rhs.signal.displayState.priority
                }
                return lhs.updatedAt < rhs.updatedAt
            }) else {
                return nil
            }

            return Candidate(
                scope: scope,
                priority: bestSession.signal.displayState.priority,
                updatedAt: bestSession.updatedAt
            )
        }

        return candidates.max { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.scope.sortOrder > rhs.scope.sortOrder
        }?.scope
    }

    private static func isFollowCandidateSession(_ session: SessionStatus) -> Bool {
        if isSignalTestEvent(session.lastEvent) {
            return false
        }

        if ActivityPresentation.isPresenceOnlySession(session) {
            return false
        }

        switch session.signal.displayState {
        case .paused:
            return false
        case .ready, .active, .completed, .needsReview, .permission, .blocked, .stale:
            return true
        }
    }

    private static func aggregateForSignalLightScopes(
        sessions: [SessionStatus],
        fallback: AgentSignal,
        scopes: Set<SignalLightAgentScope>,
        selectionMode: SignalLightAgentSelectionMode
    ) -> AgentSignal {
        let selectedSignals = sessions.compactMap { session -> AgentSignal? in
            guard Self.session(session, matches: scopes) else { return nil }
            return session.signal
        }

        if let aggregate = selectedSignals
            .max(by: { lhs, rhs in lhs.displayState.priority < rhs.displayState.priority })?
            .normalizedAggregateSignal {
            return aggregate
        }

        return fallbackForEmptySignalLightSessions(
            fallback,
            scopes: scopes,
            selectionMode: selectionMode
        )
    }

    private static func aggregateForSessions(
        _ sessions: [SessionStatus],
        fallback: AgentSignal
    ) -> AgentSignal {
        if let aggregate = sessions
            .map(\.signal)
            .max(by: { lhs, rhs in lhs.displayState.priority < rhs.displayState.priority })?
            .normalizedAggregateSignal {
            return aggregate
        }

        return fallbackForEmptyDisplaySessions(fallback)
    }

    private static func fallbackForEmptyDisplaySessions(_ fallback: AgentSignal) -> AgentSignal {
        switch fallback.displayState {
        case .paused, .blocked:
            return fallback.normalizedAggregateSignal
        case .ready, .active, .completed, .needsReview, .permission, .stale:
            return .idle
        }
    }

    private static func fallbackForEmptySignalLightSessions(
        _ fallback: AgentSignal,
        scopes: Set<SignalLightAgentScope>,
        selectionMode: SignalLightAgentSelectionMode
    ) -> AgentSignal {
        if selectionMode == .manual, !scopes.isEmpty {
            switch fallback.displayState {
            case .paused:
                return fallback.normalizedAggregateSignal
            case .ready, .active, .completed, .needsReview, .permission, .blocked, .stale:
                return .idle
            }
        }

        return fallbackForEmptyDisplaySessions(fallback)
    }

    private static func session(_ session: SessionStatus, matches scopes: Set<SignalLightAgentScope>) -> Bool {
        scopes.contains { $0.matches(session: session) }
    }

    private static func event(_ event: RecentSignalEvent, matches scopes: Set<SignalLightAgentScope>) -> Bool {
        scopes.contains { $0.matches(event: event) }
    }

    private static func deduplicatedDisplaySessions(_ sessions: [SessionStatus]) -> [SessionStatus] {
        var sessionsBySourceKey: [String: SessionStatus] = [:]

        for session in sessions {
            let sourceKey = ActivityPresentation.activitySourceKey(for: session)
            guard let current = sessionsBySourceKey[sourceKey] else {
                sessionsBySourceKey[sourceKey] = session
                continue
            }

            if shouldPreferDisplaySession(session, over: current) {
                sessionsBySourceKey[sourceKey] = session
            }
        }

        return sessionsBySourceKey.values.sorted(by: displaySessionSortPrecedes)
    }

    private static func displaySessionSortPrecedes(_ lhs: SessionStatus, _ rhs: SessionStatus) -> Bool {
        if lhs.signal.displayState.priority != rhs.signal.displayState.priority {
            return lhs.signal.displayState.priority > rhs.signal.displayState.priority
        }

        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }

        return ActivityPresentation.activitySourceKey(for: lhs)
            < ActivityPresentation.activitySourceKey(for: rhs)
    }

    private static func shouldPreferDisplaySession(_ candidate: SessionStatus, over current: SessionStatus) -> Bool {
        let candidateIsDesktopPresence = ActivityPresentation.isPresenceSession(candidate)
        let currentIsDesktopPresence = ActivityPresentation.isPresenceSession(current)
        if candidateIsDesktopPresence != currentIsDesktopPresence {
            if candidateIsDesktopPresence {
                return shouldPresenceOverrideStaleActivity(candidate, nonPresence: current)
            }
            if currentIsDesktopPresence {
                return !shouldPresenceOverrideStaleActivity(current, nonPresence: candidate)
            }
        }

        if shouldResolvingDisplaySessionOverride(candidate, current: current) {
            return true
        }
        if shouldResolvingDisplaySessionOverride(current, current: candidate) {
            return false
        }

        let candidateIsAlert = isPersistentAlert(candidate.signal.displayState)
        let currentIsAlert = isPersistentAlert(current.signal.displayState)
        if candidateIsAlert || currentIsAlert {
            let candidatePriority = deduplicationPriority(for: candidate.signal)
            let currentPriority = deduplicationPriority(for: current.signal)
            if candidatePriority != currentPriority {
                return candidatePriority > currentPriority
            }
        }

        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
        }

        return deduplicationPriority(for: candidate.signal) > deduplicationPriority(for: current.signal)
    }

    private static func shouldResolvingDisplaySessionOverride(
        _ candidate: SessionStatus,
        current: SessionStatus
    ) -> Bool {
        isResolvingSignal(candidate.signal)
            && shouldResolvingEventSupersedeSessionDisplayState(current.signal.displayState)
            && candidate.updatedAt >= current.updatedAt
    }

    private static func shouldPresenceOverrideStaleActivity(
        _ presence: SessionStatus,
        nonPresence: SessionStatus
    ) -> Bool {
        guard nonPresence.signal.displayState == .active else {
            return false
        }

        return presence.updatedAt.timeIntervalSince(nonPresence.updatedAt) > activeDisplayWindow(for: nonPresence)
    }

    private static func deduplicationPriority(for signal: AgentSignal) -> Int {
        signal.displayState.priority
    }

    private static func isPersistentAlert(_ displayState: DisplayState) -> Bool {
        switch displayState {
        case .completed, .needsReview, .permission, .blocked, .stale, .paused:
            return true
        case .ready, .active:
            return false
        }
    }

    private static func recentActivityFallbackWindow(for event: RecentSignalEvent) -> TimeInterval {
        isPassiveActiveEvent(event) ? passiveActiveDisplayWindow : recentActivityFallbackWindow
    }

    private static func isPassiveActiveEvent(_ event: RecentSignalEvent) -> Bool {
        guard event.signal.displayState == .active else { return false }

        switch event.event {
        case "DesktopActivityHeartbeat", "DesktopThinking", "DesktopMessage":
            return true
        default:
            return false
        }
    }

    private static func latestCompletionCutoffsBySourceKey(_ events: [RecentSignalEvent]) -> [String: Date] {
        var cutoffs: [String: Date] = [:]

        for event in events where event.signal.displayState == .completed {
            let sourceKey = ActivityPresentation.activitySourceKey(for: event)
            if let existing = cutoffs[sourceKey], existing >= event.updatedAt {
                continue
            }
            cutoffs[sourceKey] = event.updatedAt
        }

        return cutoffs
    }

    private static func latestResolvingCutoffsBySourceKey(_ events: [RecentSignalEvent]) -> [String: Date] {
        var cutoffs: [String: Date] = [:]

        for event in events where isResolvingSignal(event.signal) {
            let sourceKey = ActivityPresentation.activitySourceKey(for: event)
            if let existing = cutoffs[sourceKey], existing >= event.updatedAt {
                continue
            }
            cutoffs[sourceKey] = event.updatedAt
        }

        return cutoffs
    }

    private static func isSupersededByCompletedRecentEvent(
        _ session: SessionStatus,
        completionCutoffsBySourceKey: [String: Date]
    ) -> Bool {
        guard !ActivityPresentation.isPresenceSession(session),
              shouldCompletedEventSupersedeDisplayState(session.signal.displayState)
        else {
            return false
        }

        let sourceKey = ActivityPresentation.activitySourceKey(for: session)
        guard let completedAt = completionCutoffsBySourceKey[sourceKey] else {
            return false
        }

        return completedAt >= session.updatedAt
    }

    private static func isSupersededByCompletedRecentEvent(
        _ event: RecentSignalEvent,
        completionCutoffsBySourceKey: [String: Date]
    ) -> Bool {
        guard event.signal.displayState == .active else {
            return false
        }

        let sourceKey = ActivityPresentation.activitySourceKey(for: event)
        guard let completedAt = completionCutoffsBySourceKey[sourceKey] else {
            return false
        }

        return completedAt >= event.updatedAt
    }

    private static func isSupersededByResolvingRecentEvent(
        _ session: SessionStatus,
        resolvingCutoffsBySourceKey: [String: Date]
    ) -> Bool {
        guard !ActivityPresentation.isPresenceSession(session),
              shouldResolvingEventSupersedeSessionDisplayState(session.signal.displayState)
        else {
            return false
        }

        let sourceKey = ActivityPresentation.activitySourceKey(for: session)
        guard let resolvedAt = resolvingCutoffsBySourceKey[sourceKey] else {
            return false
        }

        return resolvedAt >= session.updatedAt
    }

    private static func isSupersededByResolvingRecentEvent(
        _ event: RecentSignalEvent,
        resolvingCutoffsBySourceKey: [String: Date]
    ) -> Bool {
        guard shouldResolvingEventSupersedeDisplayState(event.signal.displayState) else {
            return false
        }

        let sourceKey = ActivityPresentation.activitySourceKey(for: event)
        guard let resolvedAt = resolvingCutoffsBySourceKey[sourceKey] else {
            return false
        }

        return resolvedAt > event.updatedAt
    }

    private static func shouldResolvingEventSupersedeDisplayState(_ displayState: DisplayState) -> Bool {
        switch displayState {
        case .needsReview, .permission:
            return true
        case .ready, .active, .completed, .blocked, .stale, .paused:
            return false
        }
    }

    private static func shouldResolvingEventSupersedeSessionDisplayState(_ displayState: DisplayState) -> Bool {
        switch displayState {
        case .needsReview, .permission:
            return true
        case .ready, .active, .completed, .blocked, .stale, .paused:
            return false
        }
    }

    private static func shouldCompletedEventSupersedeDisplayState(_ displayState: DisplayState) -> Bool {
        switch displayState {
        case .active, .needsReview, .permission:
            return true
        case .ready, .completed, .blocked, .stale, .paused:
            return false
        }
    }

    private static func isResolvingSignal(_ signal: AgentSignal) -> Bool {
        switch signal {
        case .thinking, .working, .toolDone, .subagentStart, .subagentStop, .done:
            return true
        case .idle, .attention, .notification, .permission,
             .permissionRequest, .blocked, .failure, .error, .exception, .maxTokens,
             .stale, .sessionStart, .sessionEnd, .turnEnd, .off, .pause, .paused:
            return false
        }
    }

    private static func deduplicatedRecentEvents(_ events: [RecentSignalEvent]) -> [RecentSignalEvent] {
        var acceptedAtByKey: [String: Date] = [:]
        var result: [RecentSignalEvent] = []

        for event in events {
            let key = recentEventDeduplicationKey(for: event)
            if let acceptedAt = acceptedAtByKey[key],
               abs(acceptedAt.timeIntervalSince(event.updatedAt)) <= recentEventDeduplicationWindow {
                continue
            }

            acceptedAtByKey[key] = event.updatedAt
            result.append(event)
        }

        return result
    }

    private static func recentEventDeduplicationKey(for event: RecentSignalEvent) -> String {
        let sourceKey = ActivityPresentation.activitySourceKey(for: event)
        let semanticEvent = normalizedEventDeduplicationKey(event.event, signal: event.signal)
        return "\(sourceKey)|\(semanticEvent)"
    }

    private static func normalizedEventDeduplicationKey(_ event: String?, signal: AgentSignal) -> String {
        guard let event,
              !event.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return signal.normalizedAggregateSignal.rawValue
        }

        let normalized = event
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        if normalized.hasPrefix("desktoptoolcall:") {
            return "tool-call:\(String(normalized.dropFirst("desktoptoolcall:".count)))"
        }

        if normalized.hasPrefix("pretooluse:") {
            return "tool-call:\(String(normalized.dropFirst("pretooluse:".count)))"
        }

        if normalized.hasPrefix("posttooluse:") || normalized.hasPrefix("posttoolusefailure:") {
            return normalized.hasPrefix("posttoolusefailure:") ? "tool-failed" : "tool-done"
        }

        switch normalized {
        case "desktopthinking", "desktoptaskstarted", "userpromptsubmit":
            return "thinking"
        case "desktopmessage", "pretooluse", "tooluse", "tool-use":
            return "tool-call"
        case "desktoptooldone", "posttooluse", "posttoolbatch", "function-call-output":
            return "tool-done"
        case "desktoptaskcomplete", "desktopturnaborted", "stop", "taskcompleted":
            return "done"
        case "permissionrequest", "permission-request":
            return "permission"
        default:
            return "\(signal.normalizedAggregateSignal.rawValue):\(normalized)"
        }
    }

    private static func storedSessionExclusionReason(
        _ session: SessionStatus,
        now: Date,
        completedDisplayWindow: TimeInterval,
        transientAlertDisplayWindow: TimeInterval
    ) -> String? {
        if isSignalTestEvent(session.lastEvent) {
            return "signal_test"
        }

        if ActivityPresentation.isPresenceSession(session) {
            return "presence_session"
        }

        switch session.signal.displayState {
        case .active:
            return now.timeIntervalSince(session.updatedAt) <= activeDisplayWindow(for: session)
                ? nil
                : "activity_window_expired"
        case .completed:
            return now.timeIntervalSince(session.updatedAt) <= completedDisplayWindow
                ? nil
                : "completed_window_expired"
        case .needsReview, .permission, .blocked, .stale:
            return now.timeIntervalSince(session.updatedAt) <= transientAlertDisplayWindow
                ? nil
                : "attention_window_expired"
        case .ready, .paused:
            return "not_displayable"
        }
    }

    private static func shouldSuppressDesktopPresence(
        for session: SessionStatus,
        now: Date,
        transientAlertDisplayWindow: TimeInterval
    ) -> Bool {
        if isSignalTestEvent(session.lastEvent) {
            return false
        }

        switch session.signal.displayState {
        case .active:
            return now.timeIntervalSince(session.updatedAt) <= activeDisplayWindow(for: session)
        case .needsReview, .permission:
            return now.timeIntervalSince(session.updatedAt) <= transientAlertDisplayWindow
        case .blocked, .stale:
            return true
        case .ready, .completed, .paused:
            return false
        }
    }

    private static func activeDisplayWindow(for session: SessionStatus) -> TimeInterval {
        isPassiveActiveSession(session) ? passiveActiveDisplayWindow : activeDisplayWindow
    }

    private static func isPassiveActiveSession(_ session: SessionStatus) -> Bool {
        guard session.signal.displayState == .active else { return false }

        switch session.lastEvent {
        case "DesktopActivityHeartbeat", "DesktopThinking", "DesktopMessage":
            return true
        default:
            return false
        }
    }

    private static func isSignalTestEvent(_ event: String?) -> Bool {
        event == "SignalTest" || event == "SignalTestOff"
    }

    private static func fallbackRejectionReason(_ event: RecentSignalEvent) -> String {
        if ActivityPresentation.isManualIdleControlEvent(event) {
            return "manual_idle"
        }

        switch event.signal.displayState {
        case .ready, .paused:
            return "not_fallback"
        case .active:
            return "activity_window_expired"
        case .completed:
            return "completed_window_expired"
        case .needsReview, .permission, .blocked, .stale:
            return "attention_window_expired"
        }
    }

    private static func appendFallbackExclusion(
        for event: RecentSignalEvent,
        reason: String,
        into exclusions: inout [Exclusion]
    ) {
        switch event.signal.displayState {
        case .needsReview, .permission, .blocked, .stale, .completed:
            exclusions.append(exclusion(for: event, reason: reason))
        case .ready, .active, .paused:
            break
        }
    }

    private static func exclusion(for session: SessionStatus, reason: String) -> Exclusion {
        Exclusion(
            sessionID: session.sessionID,
            agent: session.agent,
            event: session.lastEvent,
            signal: session.signal,
            updatedAt: session.updatedAt,
            reason: reason
        )
    }

    private static func exclusion(for event: RecentSignalEvent, reason: String) -> Exclusion {
        Exclusion(
            sessionID: event.sessionID,
            agent: event.agent,
            event: event.event,
            signal: event.signal,
            updatedAt: event.updatedAt,
            reason: reason
        )
    }
}
