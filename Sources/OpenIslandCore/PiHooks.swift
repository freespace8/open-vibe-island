import Foundation

public enum PiHookEventName: String, Codable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"
}

public struct PiHookPayload: Equatable, Codable, Sendable {
    public var hookEventName: PiHookEventName
    public var sessionID: String
    public var cwd: String
    public var transcriptPath: String?
    public var toolName: String?
    public var toolInput: String?
    public var prompt: String?
    public var lastAssistantMessage: String?
    public var model: String?
    public var terminalApp: String?
    public var terminalSessionID: String?
    public var terminalTTY: String?
    public var terminalTitle: String?

    private enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case prompt
        case lastAssistantMessage = "last_assistant_message"
        case model
        case terminalApp = "terminal_app"
        case terminalSessionID = "terminal_session_id"
        case terminalTTY = "terminal_tty"
        case terminalTitle = "terminal_title"
    }

    public init(
        hookEventName: PiHookEventName,
        sessionID: String,
        cwd: String,
        transcriptPath: String? = nil,
        toolName: String? = nil,
        toolInput: String? = nil,
        prompt: String? = nil,
        lastAssistantMessage: String? = nil,
        model: String? = nil,
        terminalApp: String? = nil,
        terminalSessionID: String? = nil,
        terminalTTY: String? = nil,
        terminalTitle: String? = nil
    ) {
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.toolName = toolName
        self.toolInput = toolInput
        self.prompt = prompt
        self.lastAssistantMessage = lastAssistantMessage
        self.model = model
        self.terminalApp = terminalApp
        self.terminalSessionID = terminalSessionID
        self.terminalTTY = terminalTTY
        self.terminalTitle = terminalTitle
    }
}

public struct PiExtensionInstallationStatus: Equatable, Sendable {
    public var piAgentDirectory: URL
    public var extensionsDirectory: URL
    public var extensionFileURL: URL
    public var manifestURL: URL
    public var extensionFilePresent: Bool
    public var manifest: PiExtensionInstallerManifest?

    public var isInstalled: Bool {
        extensionFilePresent
    }

    public init(
        piAgentDirectory: URL,
        extensionsDirectory: URL,
        extensionFileURL: URL,
        manifestURL: URL,
        extensionFilePresent: Bool,
        manifest: PiExtensionInstallerManifest?
    ) {
        self.piAgentDirectory = piAgentDirectory
        self.extensionsDirectory = extensionsDirectory
        self.extensionFileURL = extensionFileURL
        self.manifestURL = manifestURL
        self.extensionFilePresent = extensionFilePresent
        self.manifest = manifest
    }
}

public struct PiExtensionInstallerManifest: Equatable, Codable, Sendable {
    public static let fileName = "open-island-pi-extension-install.json"

    public var extensionPath: String
    public var installedAt: Date

    public init(extensionPath: String, installedAt: Date = .now) {
        self.extensionPath = extensionPath
        self.installedAt = installedAt
    }
}

public final class PiExtensionInstallationManager: @unchecked Sendable {
    public static let extensionFileName = "open-island.ts"

    public let piAgentDirectory: URL
    private let fileManager: FileManager

    public init(
        piAgentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.piAgentDirectory = piAgentDirectory
        self.fileManager = fileManager
    }

    private var extensionsDirectory: URL {
        piAgentDirectory.appendingPathComponent("extensions", isDirectory: true)
    }

    private var extensionFileURL: URL {
        extensionsDirectory.appendingPathComponent(Self.extensionFileName)
    }

    private var manifestURL: URL {
        piAgentDirectory.appendingPathComponent(PiExtensionInstallerManifest.fileName)
    }

    public func status() throws -> PiExtensionInstallationStatus {
        PiExtensionInstallationStatus(
            piAgentDirectory: piAgentDirectory,
            extensionsDirectory: extensionsDirectory,
            extensionFileURL: extensionFileURL,
            manifestURL: manifestURL,
            extensionFilePresent: fileManager.fileExists(atPath: extensionFileURL.path),
            manifest: try loadManifest()
        )
    }

    @discardableResult
    public func install(extensionSourceData: Data) throws -> PiExtensionInstallationStatus {
        try fileManager.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: extensionFileURL.path) {
            try backupFile(at: extensionFileURL)
        }
        try extensionSourceData.write(to: extensionFileURL, options: .atomic)

        let manifest = PiExtensionInstallerManifest(extensionPath: extensionFileURL.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        return try status()
    }

    @discardableResult
    public func uninstall() throws -> PiExtensionInstallationStatus {
        if fileManager.fileExists(atPath: extensionFileURL.path) {
            try fileManager.removeItem(at: extensionFileURL)
        }

        if fileManager.fileExists(atPath: manifestURL.path) {
            try fileManager.removeItem(at: manifestURL)
        }

        return try status()
    }

    private func loadManifest() throws -> PiExtensionInstallerManifest? {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PiExtensionInstallerManifest.self, from: data)
    }

    private func backupFile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backupURL = url.appendingPathExtension("backup.\(timestamp)")
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: url, to: backupURL)
    }
}

public extension PiHookPayload {
    var workspaceName: String {
        WorkspaceNameResolver.workspaceName(for: cwd)
    }

    var sessionTitle: String {
        "Pi · \(workspaceName)"
    }

    var defaultJumpTarget: JumpTarget {
        JumpTarget(
            terminalApp: terminalApp ?? "Unknown",
            workspaceName: workspaceName,
            paneTitle: terminalTitle ?? "Pi \(sessionID.prefix(8))",
            workingDirectory: cwd,
            terminalSessionID: terminalSessionID,
            terminalTTY: terminalTTY
        )
    }

    var defaultPiMetadata: PiSessionMetadata {
        PiSessionMetadata(
            transcriptPath: transcriptPath,
            initialUserPrompt: promptPreview,
            lastUserPrompt: promptPreview,
            lastAssistantMessage: assistantMessagePreview,
            currentTool: toolName,
            currentCommandPreview: toolInputPreview
        )
    }

    var implicitStartSummary: String {
        switch hookEventName {
        case .sessionStart:
            return "Started Pi session in \(workspaceName)."
        case .userPromptSubmit:
            return "Pi received a new prompt in \(workspaceName)."
        case .preToolUse:
            return "Pi is preparing \(toolName ?? "a tool") in \(workspaceName)."
        case .postToolUse:
            return "Pi finished \(toolName ?? "a tool") in \(workspaceName)."
        case .stop:
            return "Pi completed a turn in \(workspaceName)."
        case .sessionEnd:
            return "Pi session ended in \(workspaceName)."
        }
    }

    var promptPreview: String? {
        clipped(prompt)
    }

    var assistantMessagePreview: String? {
        clipped(lastAssistantMessage)
    }

    var toolInputPreview: String? {
        clipped(toolInput)
    }

    private func clipped(_ value: String?, limit: Int = 110) -> String? {
        guard let value else {
            return nil
        }

        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        guard !collapsed.isEmpty else {
            return nil
        }

        guard collapsed.count > limit else {
            return collapsed
        }

        return "\(collapsed.prefix(limit - 1))…"
    }
}
