import AgentSignalLightCore
import Foundation

extension MenuBarStatusModel {
    func activitySessionTitle(for session: SessionStatus) -> String {
        "\(friendlyAgentName(session.agent)) · \(activitySessionRuntimeLabel(for: session))"
    }

    func activitySessionRuntimeLabel(for session: SessionStatus) -> String {
        let presenceOnly = ActivityPresentation.isPresenceOnlySession(session)
        let state = activitySessionStateLabel(for: session.signal.displayState)

        switch ActivityPresentation.runtimeKind(for: session) {
        case .desktop:
            return presenceOnly
                ? text("桌面版已开启", "Desktop app open")
                : text("桌面版\(state.zh)", "Desktop \(state.en)")
        case .terminal:
            return presenceOnly
                ? text("终端已检测到", "Terminal detected")
                : text("终端\(state.zh)", "Terminal \(state.en)")
        case .ide:
            let place = ActivityPresentation.sourceDetail(for: session) ?? "IDE"
            return presenceOnly
                ? text("\(place) 已检测到", "\(place) detected")
                : text("\(place) \(state.zh)", "\(place) \(state.en)")
        case .local:
            return presenceOnly
                ? text("本地已检测到", "Local detected")
                : text("本地\(state.zh)", "Local \(state.en)")
        }
    }

    private func activitySessionStateLabel(for displayState: DisplayState) -> (zh: String, en: String) {
        switch displayState {
        case .ready, .active:
            return ("运行中", "running")
        case .completed:
            return ("已完成", "done")
        case .needsReview:
            return ("待查看", "needs review")
        case .permission:
            return ("等待授权", "waiting for permission")
        case .blocked:
            return ("已阻塞", "blocked")
        case .stale:
            return ("无响应", "stale")
        case .paused:
            return ("已暂停", "paused")
        }
    }

    func activitySessionStatusSubtitle(for session: SessionStatus) -> String {
        ActivityPresentation.statusSubtitle(
            for: session,
            status: displayName(for: session.signal),
            friendlyEventName: friendlyEventName
        )
    }

    func activityEventTitle(for event: RecentSignalEvent) -> String {
        ActivityPresentation.eventTitle(
            for: event,
            agentName: activityEventAgentTitle(for: event)
        )
    }

    func activityEventSubtitle(for event: RecentSignalEvent) -> String {
        ActivityPresentation.eventSubtitle(
            for: event,
            status: displayName(for: event.signal),
            friendlyEventName: friendlyEventName
        )
    }

    private func activityEventAgentTitle(for event: RecentSignalEvent) -> String {
        let baseName = friendlyAgentName(event.agent)

        switch ActivityPresentation.runtimeKind(for: event) {
        case .desktop:
            return "\(baseName) Desktop"
        case .terminal:
            return "\(baseName) CLI"
        case .ide:
            if let detail = ActivityPresentation.sourceDetail(for: event) {
                return "\(baseName) \(detail)"
            }
            return "\(baseName) IDE"
        case .local:
            return baseName
        }
    }
}
