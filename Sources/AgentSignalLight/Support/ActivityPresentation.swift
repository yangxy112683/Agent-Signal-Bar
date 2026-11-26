import AgentSignalLightCore
import Foundation

extension MenuBarStatusModel {
    func activitySessionTitle(for session: SessionStatus) -> String {
        "\(friendlyAgentName(session.agent)) · \(activitySessionRuntimeLabel(for: session))"
    }

    func activitySessionRuntimeLabel(for session: SessionStatus) -> String {
        let presenceOnly = ActivityPresentation.isPresenceOnlySession(session)

        switch ActivityPresentation.runtimeKind(for: session) {
        case .desktop:
            return presenceOnly
                ? text("桌面版已开启", "Desktop app open")
                : text("桌面版运行中", "Desktop running")
        case .terminal:
            return presenceOnly
                ? text("终端已检测到", "Terminal detected")
                : text("终端运行中", "Terminal running")
        case .ide:
            if let detail = ActivityPresentation.sourceDetail(for: session) {
                return presenceOnly
                    ? text("\(detail) 已检测到", "\(detail) detected")
                    : text("\(detail) 运行中", "\(detail) running")
            }
            return presenceOnly
                ? text("IDE 已检测到", "IDE detected")
                : text("IDE 运行中", "IDE running")
        case .local:
            return presenceOnly
                ? text("本地已检测到", "Local detected")
                : text("本地运行中", "Local running")
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
