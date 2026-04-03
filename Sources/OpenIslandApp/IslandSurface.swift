import Foundation
import OpenIslandCore

enum IslandSurface: Equatable {
    case sessionList
    case approvalCard(sessionID: String)
    case questionCard(sessionID: String)
    case completionCard(sessionID: String)

    var sessionID: String? {
        switch self {
        case .sessionList:
            nil
        case let .approvalCard(sessionID), let .questionCard(sessionID), let .completionCard(sessionID):
            sessionID
        }
    }

    var isNotificationCard: Bool {
        switch self {
        case .sessionList:
            false
        case .approvalCard, .questionCard, .completionCard:
            true
        }
    }

    var autoDismissesWhenPresentedAsNotification: Bool {
        switch self {
        case .completionCard:
            true
        case .sessionList, .approvalCard, .questionCard:
            false
        }
    }

    static func notificationSurface(for event: AgentEvent) -> IslandSurface? {
        switch event {
        case let .permissionRequested(payload):
            .approvalCard(sessionID: payload.sessionID)
        case let .questionAsked(payload):
            .questionCard(sessionID: payload.sessionID)
        case let .sessionCompleted(payload):
            .completionCard(sessionID: payload.sessionID)
        default:
            nil
        }
    }

    func matchesCurrentState(of session: AgentSession?) -> Bool {
        guard let session else {
            return false
        }

        switch self {
        case .sessionList:
            return true
        case .approvalCard:
            return session.phase == .waitingForApproval && session.permissionRequest != nil
        case .questionCard:
            return session.phase == .waitingForAnswer && session.questionPrompt != nil
        case .completionCard:
            return session.phase == .completed
        }
    }
}
