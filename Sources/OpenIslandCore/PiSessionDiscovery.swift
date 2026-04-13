import Foundation

public typealias PiSessionMetadata = CodexSessionMetadata

public struct PiTrackedSessionRecord: Equatable, Codable, Sendable {
    public var sessionID: String
    public var title: String
    public var origin: SessionOrigin?
    public var attachmentState: SessionAttachmentState
    public var summary: String
    public var phase: SessionPhase
    public var updatedAt: Date
    public var jumpTarget: JumpTarget?
    public var piMetadata: PiSessionMetadata?

    public init(
        sessionID: String,
        title: String,
        origin: SessionOrigin? = nil,
        attachmentState: SessionAttachmentState = .stale,
        summary: String,
        phase: SessionPhase,
        updatedAt: Date,
        jumpTarget: JumpTarget? = nil,
        piMetadata: PiSessionMetadata? = nil
    ) {
        self.sessionID = sessionID
        self.title = title
        self.origin = origin
        self.attachmentState = attachmentState
        self.summary = summary
        self.phase = phase
        self.updatedAt = updatedAt
        self.jumpTarget = jumpTarget
        self.piMetadata = piMetadata
    }

    public init(session: AgentSession) {
        self.init(
            sessionID: session.id,
            title: session.title,
            origin: session.origin,
            attachmentState: session.attachmentState,
            summary: session.summary,
            phase: session.phase,
            updatedAt: session.updatedAt,
            jumpTarget: session.jumpTarget,
            piMetadata: session.piMetadata
        )
    }

    public var session: AgentSession {
        AgentSession(
            id: sessionID,
            title: title,
            tool: .piAgent,
            origin: origin,
            attachmentState: attachmentState,
            phase: phase,
            summary: summary,
            updatedAt: updatedAt,
            jumpTarget: jumpTarget,
            piMetadata: piMetadata
        )
    }

    public var restorableSession: AgentSession {
        var session = session
        session.attachmentState = .stale
        return session
    }
}

public extension PiTrackedSessionRecord {
    var shouldRestoreToLiveState: Bool {
        origin != .demo
    }
}

public final class PiSessionRegistry: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager

    public static var defaultDirectoryURL: URL {
        CodexSessionStore.defaultDirectoryURL
    }

    public static var defaultFileURL: URL {
        defaultDirectoryURL.appendingPathComponent("pi-session-registry.json")
    }

    public init(
        fileURL: URL = PiSessionRegistry.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> [PiTrackedSessionRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PiTrackedSessionRecord].self, from: data)
    }

    public func save(_ records: [PiTrackedSessionRecord]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: .atomic)
    }
}

public final class PiSessionDiscovery: @unchecked Sendable {
    private struct Candidate {
        var fileURL: URL
        var modifiedAt: Date
    }

    nonisolated(unsafe) private static let iso8601Formatter = ISO8601DateFormatter()

    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let maxAge: TimeInterval
    private let maxFiles: Int

    public init(
        rootURL: URL = PiSessionDiscovery.defaultRootURL,
        fileManager: FileManager = .default,
        maxAge: TimeInterval = 86_400,
        maxFiles: Int = 40
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.maxAge = maxAge
        self.maxFiles = maxFiles
    }

    public func discoverRecentSessions(now: Date = .now) -> [AgentSession] {
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let cutoff = now.addingTimeInterval(-maxAge)
        var candidates: [Candidate] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else {
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate,
                  modifiedAt >= cutoff else {
                continue
            }

            candidates.append(Candidate(fileURL: fileURL, modifiedAt: modifiedAt))
        }

        return candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxFiles)
            .compactMap { parseSession(at: $0.fileURL, fallbackUpdatedAt: $0.modifiedAt) }
    }

    private func parseSession(at fileURL: URL, fallbackUpdatedAt: Date) -> AgentSession? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        var sessionID: String?
        var cwd: String?
        var updatedAt = fallbackUpdatedAt
        var initialUserPrompt: String?
        var lastUserPrompt: String?
        var lastAssistantMessage: String?
        var currentTool: String?
        var currentCommandPreview: String?
        var pendingToolCalls: [String: (name: String, preview: String?)] = [:]

        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let value = object["id"] as? String, !value.isEmpty, sessionID == nil {
                sessionID = value
            }

            if let value = object["cwd"] as? String, !value.isEmpty, cwd == nil {
                cwd = value
            }

            if let timestampText = object["timestamp"] as? String,
               let timestamp = Self.iso8601Formatter.date(from: timestampText) {
                updatedAt = timestamp
            }

            guard object["type"] as? String == "message",
                  let message = object["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  let content = message["content"] as? [[String: Any]] else {
                continue
            }

            switch role {
            case "user":
                if let prompt = firstText(in: content) {
                    if initialUserPrompt == nil {
                        initialUserPrompt = prompt
                    }
                    lastUserPrompt = prompt
                }
            case "assistant":
                if let text = firstText(in: content) {
                    lastAssistantMessage = text
                }

                let toolCalls = toolCalls(in: content)
                for toolCall in toolCalls {
                    pendingToolCalls[toolCall.id] = (toolCall.name, toolCall.preview)
                }

                if let lastToolCall = toolCalls.last {
                    currentTool = lastToolCall.name
                    currentCommandPreview = lastToolCall.preview
                }
            case "toolResult":
                if let toolCallID = message["toolCallId"] as? String {
                    pendingToolCalls.removeValue(forKey: toolCallID)
                }

                if let lastPending = pendingToolCalls.values.first {
                    currentTool = lastPending.name
                    currentCommandPreview = lastPending.preview
                } else {
                    currentTool = nil
                    currentCommandPreview = nil
                }
            default:
                continue
            }
        }

        guard let sessionID, let cwd else {
            return nil
        }

        let workspaceName = WorkspaceNameResolver.workspaceName(for: cwd)
        let metadata = PiSessionMetadata(
            transcriptPath: fileURL.path,
            initialUserPrompt: initialUserPrompt,
            lastUserPrompt: lastUserPrompt,
            lastAssistantMessage: lastAssistantMessage,
            currentTool: currentTool,
            currentCommandPreview: currentCommandPreview
        )
        let summary = lastAssistantMessage
            ?? lastUserPrompt
            ?? "Recovered Pi Agent session in \(workspaceName)."

        return AgentSession(
            id: sessionID,
            title: "Pi · \(workspaceName)",
            tool: .piAgent,
            origin: .live,
            attachmentState: .stale,
            phase: .completed,
            summary: summary,
            updatedAt: updatedAt,
            jumpTarget: JumpTarget(
                terminalApp: "Unknown",
                workspaceName: workspaceName,
                paneTitle: "Pi \(sessionID.prefix(8))",
                workingDirectory: cwd
            ),
            piMetadata: metadata.isEmpty ? nil : metadata
        )
    }

    private func firstText(in content: [[String: Any]]) -> String? {
        for block in content {
            guard block["type"] as? String == "text",
                  let text = block["text"] as? String,
                  let normalized = normalizedText(text) else {
                continue
            }

            return normalized
        }

        return nil
    }

    private func toolCalls(in content: [[String: Any]]) -> [(id: String, name: String, preview: String?)] {
        content.compactMap { block in
            guard block["type"] as? String == "toolCall",
                  let id = block["id"] as? String,
                  let name = block["name"] as? String else {
                return nil
            }

            let preview: String?
            if let arguments = block["arguments"] {
                preview = previewText(forToolNamed: name, arguments: arguments)
            } else {
                preview = nil
            }

            return (id: id, name: name, preview: preview)
        }
    }

    private func previewText(forToolNamed name: String, arguments: Any) -> String? {
        if name == "bash",
           let arguments = arguments as? [String: Any],
           let command = arguments["command"] as? String {
            return normalizedText(command)
        }

        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        return normalizedText(text)
    }

    private func normalizedText(_ value: String) -> String? {
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        guard !collapsed.isEmpty else {
            return nil
        }

        guard collapsed.count > 140 else {
            return collapsed
        }

        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: 139)
        return "\(collapsed[..<endIndex])…"
    }
}
