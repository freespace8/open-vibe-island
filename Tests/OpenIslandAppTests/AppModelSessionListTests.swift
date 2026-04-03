import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct AppModelSessionListTests {
    @Test
    func islandListSessionsOnlyIncludeLiveAttachedSessions() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        model.state = SessionState(
            sessions: [
                AgentSession(
                    id: "live-session",
                    title: "Claude · active",
                    tool: .claudeCode,
                    origin: .live,
                    attachmentState: .attached,
                    phase: .running,
                    summary: "Running",
                    updatedAt: now,
                    jumpTarget: JumpTarget(
                        terminalApp: "Ghostty",
                        workspaceName: "active",
                        paneTitle: "claude ~/active",
                        workingDirectory: "/tmp/active",
                        terminalSessionID: "ghostty-1"
                    ),
                    claudeMetadata: ClaudeSessionMetadata(
                        transcriptPath: "/tmp/live.jsonl",
                        currentTool: "Task"
                    )
                ),
                AgentSession(
                    id: "recent-session",
                    title: "Claude · recent",
                    tool: .claudeCode,
                    origin: .live,
                    attachmentState: .stale,
                    phase: .completed,
                    summary: "Finished",
                    updatedAt: now.addingTimeInterval(-300),
                    jumpTarget: JumpTarget(
                        terminalApp: "Ghostty",
                        workspaceName: "recent",
                        paneTitle: "claude ~/recent",
                        workingDirectory: "/tmp/recent",
                        terminalSessionID: "ghostty-2"
                    ),
                    claudeMetadata: ClaudeSessionMetadata(
                        transcriptPath: "/tmp/recent.jsonl",
                        lastAssistantMessage: "Finished"
                    )
                ),
            ]
        )

        #expect(model.surfacedSessions.map(\.id) == ["live-session"])
        #expect(model.recentSessions.map(\.id) == ["recent-session"])
        #expect(model.islandListSessions.map(\.id) == ["live-session"])
    }

    @Test
    func hoverOpenedSessionListAutoCollapsesOnPointerExit() {
        let model = AppModel()
        model.notchStatus = .opened
        model.notchOpenReason = .hover
        model.islandSurface = .sessionList

        #expect(model.shouldAutoCollapseOnMouseLeave)

        model.handlePointerExitedIslandSurface()

        #expect(model.notchStatus == .closed)
        #expect(model.notchOpenReason == nil)
        #expect(model.islandSurface == .sessionList)
    }

    @Test
    func clickedSessionListDoesNotAutoCollapseOnPointerExit() {
        let model = AppModel()
        model.notchStatus = .opened
        model.notchOpenReason = .click
        model.islandSurface = .sessionList

        #expect(!model.shouldAutoCollapseOnMouseLeave)

        model.notePointerInsideIslandSurface()
        model.handlePointerExitedIslandSurface()

        #expect(model.notchStatus == .opened)
        #expect(model.notchOpenReason == .click)
        #expect(model.islandSurface == .sessionList)
    }

    @Test
    func completionNotificationRequiresSurfaceEntryBeforePointerExitCollapse() {
        let model = AppModel()
        model.notchStatus = .opened
        model.notchOpenReason = .notification
        model.islandSurface = .completionCard(sessionID: "session-1")

        #expect(model.shouldAutoCollapseOnMouseLeave)

        model.handlePointerExitedIslandSurface()

        #expect(model.notchStatus == .opened)
        #expect(model.notchOpenReason == .notification)

        model.notePointerInsideIslandSurface()
        model.handlePointerExitedIslandSurface()

        #expect(model.notchStatus == .closed)
        #expect(model.notchOpenReason == nil)
    }

    @Test
    func mergeDiscoveredClaudeSessionsPreservesRegistryJumpTargetAndAddsTranscriptMetadata() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        model.state = SessionState(
            sessions: [
                AgentSession(
                    id: "claude-session",
                    title: "Claude · open-island",
                    tool: .claudeCode,
                    origin: .live,
                    attachmentState: .stale,
                    phase: .completed,
                    summary: "Recovered from registry",
                    updatedAt: now.addingTimeInterval(-60),
                    jumpTarget: JumpTarget(
                        terminalApp: "Ghostty",
                        workspaceName: "open-island",
                        paneTitle: "claude ~/open-island",
                        workingDirectory: "/tmp/open-island",
                        terminalSessionID: "ghostty-claude",
                        terminalTTY: "/dev/ttys002"
                    )
                ),
            ]
        )

        let merged = model.mergeDiscoveredSessions([
            AgentSession(
                id: "claude-session",
                title: "Claude · open-island",
                tool: .claudeCode,
                origin: .live,
                attachmentState: .stale,
                phase: .running,
                summary: "Recovered from transcript",
                updatedAt: now,
                jumpTarget: JumpTarget(
                    terminalApp: "Unknown",
                    workspaceName: "open-island",
                    paneTitle: "Claude deadbeef",
                    workingDirectory: "/tmp/open-island"
                ),
                claudeMetadata: ClaudeSessionMetadata(
                    transcriptPath: "/tmp/claude.jsonl",
                    lastUserPrompt: "Check the Claude session registry.",
                    currentTool: "Task"
                )
            ),
        ])

        #expect(merged.count == 1)
        #expect(merged.first?.jumpTarget?.terminalApp == "Ghostty")
        #expect(merged.first?.jumpTarget?.terminalSessionID == "ghostty-claude")
        #expect(merged.first?.claudeMetadata?.transcriptPath == "/tmp/claude.jsonl")
        #expect(merged.first?.claudeMetadata?.lastUserPrompt == "Check the Claude session registry.")
        #expect(merged.first?.phase == .running)
    }

    @Test
    func mergedWithSyntheticClaudeSessionsAddsGhosttyClaudeProcessWhenNoTrackedSessionExists() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()

        let merged = model.mergedWithSyntheticClaudeSessions(
            existingSessions: [],
            activeProcesses: [
                .init(
                    tool: .claudeCode,
                    sessionID: nil,
                    workingDirectory: "/tmp/open-island",
                    terminalTTY: "/dev/ttys002",
                    terminalApp: "Ghostty"
                ),
            ],
            now: now
        )

        #expect(merged.count == 1)
        #expect(merged.first?.id.hasPrefix("claude-process:") == true)
        #expect(merged.first?.attachmentState == .attached)
        #expect(merged.first?.jumpTarget?.terminalApp == "Ghostty")
        #expect(merged.first?.jumpTarget?.terminalTTY == "/dev/ttys002")
    }

    @Test
    func mergedWithSyntheticClaudeSessionsSkipsSyntheticWhenAttachedClaudeAlreadyRepresentsGroup() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        let existing = AgentSession(
            id: "e45d5e87-66d0-4f67-8399-6ebc02f3d453",
            title: "Claude · open-island",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Running",
            updatedAt: now,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "open-island",
                paneTitle: "open-island · hi · e45d5e87",
                workingDirectory: "/tmp/open-island",
                terminalSessionID: "ghostty-claude"
            )
        )

        let merged = model.mergedWithSyntheticClaudeSessions(
            existingSessions: [existing],
            activeProcesses: [
                .init(
                    tool: .claudeCode,
                    sessionID: nil,
                    workingDirectory: "/tmp/open-island",
                    terminalTTY: "/dev/ttys002",
                    terminalApp: "Ghostty"
                ),
            ],
            now: now
        )

        #expect(merged.map(\.id) == [existing.id])
    }

    @Test
    func syntheticClaudeSessionWinsOverRecoveredUnknownSessionsForLiveGhosttyProcess() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        let recoveredSessions = [
            AgentSession(
                id: "e45d5e87-66d0-4f67-8399-6ebc02f3d453",
                title: "Claude · open-island",
                tool: .claudeCode,
                origin: .live,
                attachmentState: .stale,
                phase: .completed,
                summary: "Recovered transcript",
                updatedAt: now.addingTimeInterval(-10_800),
                jumpTarget: JumpTarget(
                    terminalApp: "Unknown",
                    workspaceName: "open-island",
                    paneTitle: "Claude e45d5e87",
                    workingDirectory: "/tmp/open-island"
                )
            ),
            AgentSession(
                id: "c9a48d05-c1f9-4e39-ab66-19edef0c2bc9",
                title: "Claude · open-island",
                tool: .claudeCode,
                origin: .live,
                attachmentState: .stale,
                phase: .completed,
                summary: "Recovered transcript",
                updatedAt: now.addingTimeInterval(-64_800),
                jumpTarget: JumpTarget(
                    terminalApp: "Unknown",
                    workspaceName: "open-island",
                    paneTitle: "Claude c9a48d05",
                    workingDirectory: "/tmp/open-island"
                )
            ),
        ]
        let activeProcesses: [AppModel.ActiveProcessSnapshot] = [
            .init(
                tool: .claudeCode,
                sessionID: nil,
                workingDirectory: "/tmp/open-island",
                terminalTTY: "/dev/ttys002",
                terminalApp: "Ghostty"
            ),
        ]

        let merged = model.mergedWithSyntheticClaudeSessions(
            existingSessions: recoveredSessions,
            activeProcesses: activeProcesses,
            now: now
        )
        let probe = TerminalSessionAttachmentProbe()
        let resolutions = probe.sessionResolutions(
            for: merged,
            ghosttyAvailability: .unavailable(appIsRunning: true),
            terminalAvailability: .available([] as [TerminalSessionAttachmentProbe.TerminalTabSnapshot], appIsRunning: false),
            activeProcesses: activeProcesses,
            now: now
        )

        model.state = SessionState(sessions: merged)
        _ = model.state.reconcileAttachmentStates(resolutions.mapValues(\.attachmentState))
        _ = model.state.reconcileJumpTargets(
            resolutions.reduce(into: [String: JumpTarget]()) { partialResult, entry in
                if let correctedJumpTarget = entry.value.correctedJumpTarget {
                    partialResult[entry.key] = correctedJumpTarget
                }
            }
        )

        let attachedClaudeSessions = model.state.sessions.filter {
            $0.tool == .claudeCode && $0.attachmentState == .attached
        }

        #expect(attachedClaudeSessions.count == 1)
        #expect(attachedClaudeSessions.first?.id.hasPrefix("claude-process:") == true)
        #expect(attachedClaudeSessions.first?.jumpTarget?.terminalApp == "Ghostty")
        #expect(attachedClaudeSessions.first?.jumpTarget?.terminalTTY == "/dev/ttys002")
    }
}
