import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

struct IslandSurfaceTests {
    @Test
    func permissionEventsRouteToApprovalCard() {
        let event = AgentEvent.permissionRequested(
            PermissionRequested(
                sessionID: "session-1",
                request: PermissionRequest(
                    title: "Approve command",
                    summary: "Allow exec_command to modify files?",
                    affectedPath: "/tmp/project"
                ),
                timestamp: .now
            )
        )

        #expect(IslandSurface.notificationSurface(for: event) == .approvalCard(sessionID: "session-1"))
    }

    @Test
    func questionEventsRouteToQuestionCard() {
        let event = AgentEvent.questionAsked(
            QuestionAsked(
                sessionID: "session-2",
                prompt: QuestionPrompt(
                    title: "Which environment?",
                    options: ["Production", "Staging"]
                ),
                timestamp: .now
            )
        )

        #expect(IslandSurface.notificationSurface(for: event) == .questionCard(sessionID: "session-2"))
    }

    @Test
    func approvalCardOnlyMatchesActiveApprovalState() {
        let session = AgentSession(
            id: "session-1",
            title: "Codex · repo",
            tool: .codex,
            attachmentState: .attached,
            phase: .waitingForApproval,
            summary: "Approve command",
            updatedAt: .now,
            permissionRequest: PermissionRequest(
                title: "Approve command",
                summary: "Allow exec_command to modify files?",
                affectedPath: "/tmp/project"
            )
        )

        #expect(IslandSurface.approvalCard(sessionID: "session-1").matchesCurrentState(of: session))
        #expect(!IslandSurface.questionCard(sessionID: "session-1").matchesCurrentState(of: session))
    }

    @Test
    func completionEventsRouteToCompletionCard() {
        let event = AgentEvent.sessionCompleted(
            SessionCompleted(
                sessionID: "session-3",
                summary: "Finished task",
                timestamp: .now
            )
        )

        #expect(IslandSurface.notificationSurface(for: event) == .completionCard(sessionID: "session-3"))
    }

    @Test
    func onlyCompletionCardsAutoDismissAsNotifications() {
        #expect(!IslandSurface.approvalCard(sessionID: "session-1").autoDismissesWhenPresentedAsNotification)
        #expect(!IslandSurface.questionCard(sessionID: "session-2").autoDismissesWhenPresentedAsNotification)
        #expect(IslandSurface.completionCard(sessionID: "session-3").autoDismissesWhenPresentedAsNotification)
    }
}
