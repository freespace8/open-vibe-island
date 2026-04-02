import Foundation
import VibeIslandCore

enum SpotlightActivityTone {
    case live
    case idle
    case ready
    case attention
}

extension AgentSession {
    private static let collapsedDetailAgeThreshold: TimeInterval = 2 * 60 * 60

    var spotlightPrimaryText: String {
        if let request = permissionRequest {
            return request.summary
        }

        if let prompt = questionPrompt {
            return prompt.title
        }

        if let assistantMessage = codexMetadata?.lastAssistantMessage?.trimmedForSurface,
           !assistantMessage.isEmpty {
            return assistantMessage
        }

        return summary
    }

    var spotlightSecondaryText: String? {
        if let request = permissionRequest {
            return request.affectedPath.isEmpty ? nil : request.affectedPath
        }

        if let currentTool = codexMetadata?.currentTool?.trimmedForSurface,
           !currentTool.isEmpty {
            return phase == .completed
                ? summary
                : "Running \(currentTool)"
        }

        let normalizedPrimary = spotlightPrimaryText.trimmedForSurface
        let normalizedSummary = summary.trimmedForSurface
        guard normalizedSummary != normalizedPrimary else {
            return nil
        }

        return summary
    }

    var spotlightCurrentToolLabel: String? {
        guard let currentTool = codexMetadata?.currentTool?.trimmedForSurface,
              !currentTool.isEmpty else {
            return nil
        }

        return currentTool
    }

    var spotlightTrackingLabel: String? {
        guard let transcriptPath = codexMetadata?.transcriptPath?.trimmedForSurface,
              !transcriptPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: transcriptPath).lastPathComponent
    }

    var spotlightStatusLabel: String {
        switch phase {
        case .running:
            if let currentTool = spotlightCurrentToolLabel {
                return "Live · \(currentTool)"
            }
            return "Live"
        case .waitingForApproval:
            return "Approval"
        case .waitingForAnswer:
            return "Question"
        case .completed:
            return jumpTarget != nil ? "Idle" : "Completed"
        }
    }

    var spotlightTerminalLabel: String? {
        guard let jumpTarget else {
            return nil
        }

        return "\(jumpTarget.terminalApp) · \(jumpTarget.workspaceName)"
    }

    var spotlightTerminalBadge: String? {
        jumpTarget?.terminalApp
    }

    var spotlightWorkspaceName: String {
        if let workspaceName = jumpTarget?.workspaceName.trimmedForSurface,
           !workspaceName.isEmpty {
            return workspaceName
        }

        let trimmedTitle = title.trimmedForSurface
        let pieces = trimmedTitle.split(separator: "·", maxSplits: 1).map {
            String($0).trimmedForSurface
        }
        if pieces.count == 2, !pieces[1].isEmpty {
            return pieces[1]
        }

        return trimmedTitle
    }

    var spotlightHeadlineText: String {
        guard let prompt = spotlightPromptText else {
            return spotlightWorkspaceName
        }

        return "\(spotlightWorkspaceName) · \(prompt)"
    }

    var spotlightPromptText: String? {
        let prompt = codexMetadata?.lastUserPrompt?.trimmedForSurface
        guard let prompt, !prompt.isEmpty else {
            return nil
        }

        return prompt
    }

    var spotlightPromptLineText: String? {
        guard spotlightShowsDetailLines,
              let prompt = spotlightPromptText else {
            return nil
        }

        return "You: \(prompt)"
    }

    var spotlightActivityLineText: String? {
        guard spotlightShowsDetailLines else {
            return nil
        }

        if let request = permissionRequest?.summary.trimmedForSurface,
           !request.isEmpty {
            return request
        }

        if let prompt = questionPrompt?.title.trimmedForSurface,
           !prompt.isEmpty {
            return prompt
        }

        switch phase {
        case .running:
            if let activity = spotlightRunningActivityText {
                return activity
            }
            return spotlightPromptLineText == nil ? "Running" : "Input"
        case .waitingForApproval:
            return permissionRequest?.summary.trimmedForSurface ?? "Approval needed"
        case .waitingForAnswer:
            return questionPrompt?.title.trimmedForSurface ?? "Answer needed"
        case .completed:
            if let assistantMessage = codexMetadata?.lastAssistantMessage?.trimmedForSurface,
               !assistantMessage.isEmpty {
                return assistantMessage
            }

            return jumpTarget != nil ? "Ready" : "Completed"
        }
    }

    var spotlightActivityTone: SpotlightActivityTone {
        if phase.requiresAttention {
            return .attention
        }

        switch phase {
        case .running:
            return .live
        case .completed:
            if codexMetadata?.lastAssistantMessage?.trimmedForSurface.isEmpty == false {
                return .idle
            }
            return .ready
        case .waitingForApproval, .waitingForAnswer:
            return .attention
        }
    }

    var spotlightShowsDetailLines: Bool {
        if phase == .running || phase.requiresAttention {
            return true
        }

        if Date.now.timeIntervalSince(updatedAt) >= Self.collapsedDetailAgeThreshold {
            return false
        }

        return spotlightPromptText != nil || codexMetadata?.lastAssistantMessage?.trimmedForSurface.isEmpty == false
    }

    var spotlightAgeBadge: String {
        let age = max(0, Int(Date.now.timeIntervalSince(updatedAt)))

        if age < 60 {
            return "<1m"
        }

        if age < 3_600 {
            return "\(max(1, age / 60))m"
        }

        if age < 86_400 {
            return "\(max(1, age / 3_600))h"
        }

        return "\(max(1, age / 86_400))d"
    }

    private var spotlightRunningActivityText: String? {
        guard let currentTool = codexMetadata?.currentTool?.trimmedForSurface,
              !currentTool.isEmpty else {
            return nil
        }

        let label = currentToolDisplayName(for: currentTool)
        guard let preview = codexMetadata?.currentCommandPreview?.trimmedForSurface,
              !preview.isEmpty else {
            return label
        }

        return "\(label) \(preview)"
    }

    private func currentToolDisplayName(for toolName: String) -> String {
        switch toolName {
        case "exec_command":
            return "Bash"
        case "apply_patch":
            return "Patch"
        case "write_stdin":
            return "Input"
        default:
            return toolName
        }
    }
}

private extension String {
    var trimmedForSurface: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
