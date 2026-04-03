import AppKit
import Foundation
import OpenIslandCore

struct TerminalJumpService {
    private struct TerminalAppDescriptor {
        let displayName: String
        let bundleIdentifier: String
        let aliases: [String]
    }

    private static let knownApps: [TerminalAppDescriptor] = [
        TerminalAppDescriptor(
            displayName: "iTerm",
            bundleIdentifier: "com.googlecode.iterm2",
            aliases: ["iterm", "iterm2", "iterm.app"]
        ),
        TerminalAppDescriptor(
            displayName: "Ghostty",
            bundleIdentifier: "com.mitchellh.ghostty",
            aliases: ["ghostty"]
        ),
        TerminalAppDescriptor(
            displayName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            aliases: ["terminal", "apple_terminal"]
        ),
        TerminalAppDescriptor(
            displayName: "Warp",
            bundleIdentifier: "dev.warp.Warp-Stable",
            aliases: ["warp", "warpterminal"]
        ),
        TerminalAppDescriptor(
            displayName: "WezTerm",
            bundleIdentifier: "com.github.wez.wezterm",
            aliases: ["wezterm"]
        ),
    ]

    func jump(to target: JumpTarget) throws -> String {
        let descriptor = resolveTerminalApp(preferredName: target.terminalApp)
        let hasWorkingDirectory = target.workingDirectory.map { FileManager.default.fileExists(atPath: $0) } ?? false

        if let descriptor {
            switch descriptor.bundleIdentifier {
            case "com.googlecode.iterm2":
                if try jumpToITermSession(target) {
                    return "Focused the matching iTerm session."
                }
            case "com.mitchellh.ghostty":
                if try jumpToGhosttyTerminal(target) {
                    return "Focused the matching Ghostty terminal."
                }
            case "com.apple.Terminal":
                if try jumpToTerminalTab(target) {
                    return "Focused the matching Terminal tab."
                }
            default:
                break
            }
        }

        if let descriptor, hasWorkingDirectory, let workingDirectory = target.workingDirectory {
            try runOpen(arguments: ["-b", descriptor.bundleIdentifier, workingDirectory])
            return "Opened \(target.workspaceName) in \(descriptor.displayName). Exact pane targeting is still best-effort."
        }

        if let descriptor {
            try runOpen(arguments: ["-b", descriptor.bundleIdentifier])
            return "Activated \(descriptor.displayName). Exact pane targeting is still best-effort."
        }

        if hasWorkingDirectory, let workingDirectory = target.workingDirectory {
            try runOpen(arguments: [workingDirectory])
            return "Opened \(target.workspaceName) in Finder because no supported terminal app could be resolved."
        }

        throw TerminalJumpError.unsupportedTerminal(target.terminalApp)
    }

    private func jumpToITermSession(_ target: JumpTarget) throws -> Bool {
        let script = """
        tell application "iTerm"
            if not (it is running) then return ""
            activate
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        if "\(escapeAppleScript(target.terminalSessionID))" is not "" and (id of aSession as text) is "\(escapeAppleScript(target.terminalSessionID))" then
                            select aSession
                            return "matched"
                        end if
                        if "\(escapeAppleScript(target.terminalTTY))" is not "" and (tty of aSession as text) is "\(escapeAppleScript(target.terminalTTY))" then
                            select aSession
                            return "matched"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return ""
        """

        return try runAppleScript(script) == "matched"
    }

    private func jumpToGhosttyTerminal(_ target: JumpTarget) throws -> Bool {
        let script = """
        tell application "Ghostty"
            if not (it is running) then return ""
            repeat with aTerminal in terminals
                if "\(escapeAppleScript(target.terminalSessionID))" is not "" and (id of aTerminal as text) is "\(escapeAppleScript(target.terminalSessionID))" then
                    focus aTerminal
                    return "matched"
                end if
            end repeat

            repeat with aTerminal in terminals
                if "\(escapeAppleScript(target.workingDirectory))" is not "" and (working directory of aTerminal as text) is "\(escapeAppleScript(target.workingDirectory))" then
                    focus aTerminal
                    return "matched"
                end if
            end repeat

            repeat with aTerminal in terminals
                if "\(escapeAppleScript(target.paneTitle))" is not "" and (name of aTerminal as text) contains "\(escapeAppleScript(target.paneTitle))" then
                    focus aTerminal
                    return "matched"
                end if
            end repeat
        end tell
        return ""
        """

        return try runAppleScript(script) == "matched"
    }

    private func jumpToTerminalTab(_ target: JumpTarget) throws -> Bool {
        let script = """
        tell application "Terminal"
            if not (it is running) then return ""
            activate
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    if "\(escapeAppleScript(target.terminalTTY))" is not "" and (tty of aTab as text) is "\(escapeAppleScript(target.terminalTTY))" then
                        set selected of aTab to true
                        set frontmost of aWindow to true
                        return "matched"
                    end if
                    if "\(escapeAppleScript(target.paneTitle))" is not "" and (custom title of aTab as text) contains "\(escapeAppleScript(target.paneTitle))" then
                        set selected of aTab to true
                        set frontmost of aWindow to true
                        return "matched"
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """

        return try runAppleScript(script) == "matched"
    }

    private func resolveTerminalApp(preferredName: String) -> TerminalAppDescriptor? {
        let normalized = preferredName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let exact = Self.knownApps.first(where: { descriptor in
            descriptor.displayName.lowercased() == normalized || descriptor.aliases.contains(normalized)
        }) {
            return exact
        }

        return Self.knownApps.first(where: { isInstalled(bundleIdentifier: $0.bundleIdentifier) })
    }

    private func isInstalled(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    private func runOpen(arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = arguments

        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            throw TerminalJumpError.openFailed(arguments)
        }
    }

    private func runAppleScript(_ script: String) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        try task.run()
        task.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard task.terminationStatus == 0 else {
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw TerminalJumpError.appleScriptFailed(stderr.isEmpty ? script : stderr)
        }

        return output
    }

    private func escapeAppleScript(_ value: String?) -> String {
        guard let value else {
            return ""
        }

        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum TerminalJumpError: Error, LocalizedError {
    case unsupportedTerminal(String)
    case openFailed([String])
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedTerminal(terminal):
            "Could not resolve a supported terminal app for \(terminal)."
        case let .openFailed(arguments):
            "Failed to launch terminal with arguments: \(arguments.joined(separator: " "))"
        case let .appleScriptFailed(message):
            "Terminal automation failed: \(message)"
        }
    }
}
