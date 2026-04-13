import Darwin
import Foundation
import OpenIslandCore

struct ActiveAgentProcessDiscovery {
    private static let processCommandTimeout: TimeInterval = 0.5
    private static let lsofCommandTimeout: TimeInterval = 0.2

    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }

    struct ProcessSnapshot: Equatable, Sendable {
        var tool: AgentTool
        var sessionID: String?
        var workingDirectory: String?
        var terminalTTY: String?
        var terminalApp: String?
        var transcriptPath: String?
        var tmuxTarget: String?
        var tmuxSocketPath: String?
        /// The OS process ID, used for lightweight `kill(pid, 0)` liveness checks.
        var processPID: Int32?

        init(
            tool: AgentTool,
            sessionID: String?,
            workingDirectory: String?,
            terminalTTY: String?,
            terminalApp: String? = nil,
            transcriptPath: String? = nil,
            tmuxTarget: String? = nil,
            tmuxSocketPath: String? = nil,
            processPID: Int32? = nil
        ) {
            self.tool = tool
            self.sessionID = sessionID
            self.workingDirectory = workingDirectory
            self.terminalTTY = terminalTTY
            self.terminalApp = terminalApp
            self.transcriptPath = transcriptPath
            self.tmuxTarget = tmuxTarget
            self.tmuxSocketPath = tmuxSocketPath
            self.processPID = processPID
        }
    }

    private struct RunningProcess {
        var pid: String
        var parentPID: String
        var terminalTTY: String?
        var command: String
    }

    typealias CommandRunner = @Sendable (_ executablePath: String, _ arguments: [String]) -> String?

    private let commandRunner: CommandRunner

    /// When true, use sysctl kernel calls instead of forking /bin/ps.
    /// Defaults to true in production; false when a custom commandRunner is injected (tests).
    private let useSysctl: Bool

    init(commandRunner: @escaping CommandRunner = Self.commandOutput) {
        self.commandRunner = commandRunner
        // If the caller provides a custom commandRunner (test injection),
        // fall back to the ps-parsing path so existing mock tests pass.
        self.useSysctl = false
    }

    /// Production initializer. Uses sysctl for zero-fork process enumeration.
    init(useSysctl: Bool) {
        self.commandRunner = Self.commandOutput
        self.useSysctl = useSysctl
    }

    func discover() -> [ProcessSnapshot] {
        let processes = runningProcesses()
        guard !processes.isEmpty else {
            return []
        }

        let processesByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })

        var snapshots: [ProcessSnapshot] = []
        var claimedKeys: Set<String> = []

        for process in processes {
            guard process.terminalTTY != nil else {
                continue
            }

            if isCodexProcess(command: process.command) {
                guard var snapshot = codexSnapshot(for: process, processesByPID: processesByPID) else {
                    continue
                }

                let claimKey = "codex:\(snapshot.sessionID ?? process.pid)"
                guard claimedKeys.insert(claimKey).inserted else {
                    continue
                }

                snapshot.processPID = Int32(process.pid)
                snapshots.append(snapshot)
                continue
            }

            if isClaudeProcess(command: process.command) {
                guard var snapshot = claudeSnapshot(for: process, processesByPID: processesByPID) else {
                    continue
                }

                let claimKey = "claude:\(snapshot.sessionID ?? snapshot.terminalTTY ?? snapshot.workingDirectory ?? process.pid)"
                guard claimedKeys.insert(claimKey).inserted else {
                    continue
                }

                snapshot.processPID = Int32(process.pid)
                snapshots.append(snapshot)
                continue
            }

            if isPiProcess(command: process.command) {
                guard var snapshot = piSnapshot(for: process, processesByPID: processesByPID) else {
                    continue
                }

                let claimKey = "pi:\(snapshot.sessionID ?? snapshot.transcriptPath ?? snapshot.terminalTTY ?? process.pid)"
                guard claimedKeys.insert(claimKey).inserted else {
                    continue
                }

                snapshot.processPID = Int32(process.pid)
                snapshots.append(snapshot)
                continue
            }

            if isOpenCodeProcess(command: process.command) {
                let claimKey = "opencode:\(process.pid)"
                guard claimedKeys.insert(claimKey).inserted else {
                    continue
                }

                snapshots.append(ProcessSnapshot(
                    tool: .openCode,
                    sessionID: nil,
                    workingDirectory: nil,
                    terminalTTY: process.terminalTTY,
                    processPID: Int32(process.pid)
                ))
            }
        }

        return snapshots
    }

    private func runningProcesses() -> [RunningProcess] {
        useSysctl ? runningProcessesSysctl() : runningProcessesPS()
    }

    // MARK: - sysctl-based process enumeration (zero fork)

    private func runningProcessesSysctl() -> [RunningProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else {
            return []
        }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(actualCount).compactMap { info -> RunningProcess? in
            let pid = info.kp_proc.p_pid
            let ppid = info.kp_eproc.e_ppid
            guard pid > 0 else { return nil }

            // p_comm is a 16-char short name — use it for fast pre-filtering.
            let shortName = withUnsafePointer(to: info.kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }

            guard Self.isInterestingShortName(shortName) else { return nil }

            // Full command line via KERN_PROCARGS2 (only for interesting processes).
            let fullCommand = Self.fullCommandLine(for: pid) ?? shortName

            // TTY from the kinfo_proc tdev field.
            let tty = Self.ttyDevicePath(for: info)

            return RunningProcess(
                pid: String(pid),
                parentPID: String(ppid),
                terminalTTY: tty,
                command: fullCommand
            )
        }
    }

    /// Quick filter using the 16-char short process name from kinfo_proc.p_comm.
    /// Only processes that could be agents, terminals, or multiplexers pass.
    private static func isInterestingShortName(_ name: String) -> Bool {
        let lower = name.lowercased()
        // Agent CLIs
        if lower == "codex" || lower == "claude" || lower == "opencode" || lower == "pi" { return true }
        // Node.js (Claude Code, Codex, OpenCode may run under node)
        if lower == "node" { return true }
        // Terminal emulators (needed for parent-chain terminal app resolution)
        if lower == "ghostty" || lower == "terminal" || lower == "iterm2"
            || lower == "warp" || lower == "kaku-gui" || lower == "wezterm-gui"
            || lower == "cmux" || lower == "zellij" { return true }
        // tmux (needed for tmux parent resolution)
        if lower.hasPrefix("tmux") { return true }
        // Shells (needed for parent-chain traversal from agent → shell → terminal)
        if lower == "bash" || lower == "zsh" || lower == "fish" || lower == "sh"
            || lower == "dash" || lower == "nu" { return true }
        // Electron apps (Cursor, VS Code, Windsurf, Trae)
        if lower.hasPrefix("electron") || lower.hasPrefix("code") { return true }
        return false
    }

    /// Retrieve the full command line for a process via sysctl KERN_PROCARGS2.
    private static func fullCommandLine(for pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return nil
        }

        // Layout: [argc: Int32] [exec_path\0] [padding \0s] [argv[0]\0 argv[1]\0 ...]
        let argc: Int32 = buffer.withUnsafeBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        }

        var offset = MemoryLayout<Int32>.size

        // Skip exec_path (null-terminated string)
        while offset < size && buffer[offset] != 0 { offset += 1 }
        // Skip null padding
        while offset < size && buffer[offset] == 0 { offset += 1 }

        // Collect argv[0 ..< argc]
        var args: [String] = []
        var start = offset
        for i in offset..<size {
            if buffer[i] == 0 {
                if i > start {
                    args.append(String(bytes: buffer[start..<i], encoding: .utf8) ?? "")
                }
                start = i + 1
                if args.count >= Int(argc) { break }
            }
        }

        return args.isEmpty ? nil : args.joined(separator: " ")
    }

    /// Resolve the TTY device path from kinfo_proc.kp_eproc.e_tdev.
    private static func ttyDevicePath(for info: kinfo_proc) -> String? {
        let tdev = info.kp_eproc.e_tdev
        // -1 (or NODEV) means no controlling terminal.
        guard tdev != UInt32(bitPattern: -1), tdev != 0 else { return nil }
        guard let name = devname(tdev, S_IFCHR) else { return nil }
        return "/dev/\(String(cString: name))"
    }

    // MARK: - ps-based process enumeration (fork fallback / test path)

    private func runningProcessesPS() -> [RunningProcess] {
        guard let output = commandRunner("/bin/ps", ["-Ao", "pid=,ppid=,tty=,command="]) else {
            return []
        }

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> RunningProcess? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return nil
                }

                let components = trimmed.split(maxSplits: 3, whereSeparator: \.isWhitespace)
                guard components.count == 4 else {
                    return nil
                }

                let pid = String(components[0])
                let parentPID = String(components[1])
                let tty = normalizedTTY(String(components[2]))
                let command = String(components[3]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else {
                    return nil
                }

                return RunningProcess(pid: pid, parentPID: parentPID, terminalTTY: tty, command: command)
            }
    }

    private func codexSnapshot(
        for process: RunningProcess,
        processesByPID: [String: RunningProcess]
    ) -> ProcessSnapshot? {
        guard let lsofOutput = lsofOutput(pid: process.pid),
              let transcriptPath = matchingPath(in: lsofOutput, containing: "/.codex/sessions/", suffix: ".jsonl"),
              let sessionID = firstUUID(in: transcriptPath) else {
            return nil
        }

        var snapshot = ProcessSnapshot(
            tool: .codex,
            sessionID: sessionID,
            workingDirectory: workingDirectory(from: lsofOutput),
            terminalTTY: process.terminalTTY,
            terminalApp: terminalApp(for: process, processesByPID: processesByPID)
        )

        // If terminalApp is nil and we have a TTY, try to resolve tmux info
        if snapshot.terminalApp == nil, let agentTTY = process.terminalTTY {
            if let (tmuxTarget, hostTerminalApp, socketPath) = resolveTmuxInfo(
                agentTTY: agentTTY,
                processes: processesByPID.values.map { $0 },
                processesByPID: processesByPID
            ) {
                snapshot.terminalApp = hostTerminalApp
                snapshot.tmuxTarget = tmuxTarget
                snapshot.tmuxSocketPath = socketPath
            }
        }

        return snapshot
    }

    private func isClaudeSubagentWorktree(_ path: String) -> Bool {
        path.contains("/.claude/worktrees/agent-")
    }

    private func claudeSnapshot(
        for process: RunningProcess,
        processesByPID: [String: RunningProcess]
    ) -> ProcessSnapshot? {
        let lsofOutput = lsofOutput(pid: process.pid)
        let workingDirectory = lsofOutput.flatMap(workingDirectory(from:))

        // Subagent processes run in .claude/worktrees/agent-*/ directories.
        // They are tracked as metadata on the parent session, not as separate sessions.
        if let cwd = workingDirectory, isClaudeSubagentWorktree(cwd) {
            return nil
        }

        let transcriptPath = lsofOutput.flatMap {
            bestClaudeTranscriptPath(in: $0, workingDirectory: workingDirectory)
        }
        let sessionID = transcriptPath.flatMap(firstUUID(in:))
            ?? claudeSessionID(from: process.command)

        guard workingDirectory != nil || sessionID != nil else {
            return nil
        }

        var snapshot = ProcessSnapshot(
            tool: .claudeCode,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            terminalTTY: process.terminalTTY,
            terminalApp: terminalApp(for: process, processesByPID: processesByPID),
            transcriptPath: transcriptPath
        )

        // If terminalApp is nil and we have a TTY, try to resolve tmux info
        if snapshot.terminalApp == nil, let agentTTY = process.terminalTTY {
            if let (tmuxTarget, hostTerminalApp, socketPath) = resolveTmuxInfo(
                agentTTY: agentTTY,
                processes: processesByPID.values.map { $0 },
                processesByPID: processesByPID
            ) {
                snapshot.terminalApp = hostTerminalApp
                snapshot.tmuxTarget = tmuxTarget
                snapshot.tmuxSocketPath = socketPath
            }
        }

        return snapshot
    }

    private func piSnapshot(
        for process: RunningProcess,
        processesByPID: [String: RunningProcess]
    ) -> ProcessSnapshot? {
        let lsofOutput = lsofOutput(pid: process.pid)
        let workingDirectory = lsofOutput.flatMap(workingDirectory(from:))
        let transcriptPath = lsofOutput.flatMap {
            matchingPath(in: $0, containing: "/.pi/agent/sessions/", suffix: ".jsonl")
        }
        let sessionID = transcriptPath.flatMap(firstUUID(in:))
            ?? sessionID(from: process.command, flags: ["--session", "--resume", "-r"])

        guard workingDirectory != nil || sessionID != nil || transcriptPath != nil else {
            return nil
        }

        var snapshot = ProcessSnapshot(
            tool: .piAgent,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            terminalTTY: process.terminalTTY,
            terminalApp: terminalApp(for: process, processesByPID: processesByPID),
            transcriptPath: transcriptPath
        )

        if snapshot.terminalApp == nil, let agentTTY = process.terminalTTY {
            if let (tmuxTarget, hostTerminalApp, socketPath) = resolveTmuxInfo(
                agentTTY: agentTTY,
                processes: processesByPID.values.map { $0 },
                processesByPID: processesByPID
            ) {
                snapshot.terminalApp = hostTerminalApp
                snapshot.tmuxTarget = tmuxTarget
                snapshot.tmuxSocketPath = socketPath
            }
        }

        return snapshot
    }

    private func bestClaudeTranscriptPath(in lsofOutput: String, workingDirectory: String?) -> String? {
        let paths = allMatchingPaths(in: lsofOutput, containing: "/.claude/projects/", suffix: ".jsonl")
        guard !paths.isEmpty else {
            return nil
        }

        if paths.count == 1 {
            return paths[0]
        }

        if let cwd = workingDirectory {
            let encodedCWD = cwd.replacingOccurrences(of: "/", with: "-")
            if let preferred = paths.first(where: { $0.contains(encodedCWD) }) {
                return preferred
            }
        }

        return paths.first
    }

    private func allMatchingPaths(in lsofOutput: String, containing fragment: String, suffix: String) -> [String] {
        var results: [String] = []
        for line in lsofOutput.split(whereSeparator: \.isNewline) {
            guard line.first == "n" else {
                continue
            }

            let value = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.contains(fragment), value.hasSuffix(suffix) else {
                continue
            }

            results.append(value)
        }

        return results
    }

    private func terminalApp(
        for process: RunningProcess,
        processesByPID: [String: RunningProcess]
    ) -> String? {
        var currentParentPID = process.parentPID
        var visited: Set<String> = []

        while !currentParentPID.isEmpty,
              currentParentPID != "0",
              currentParentPID != "1",
              visited.insert(currentParentPID).inserted,
              let parent = processesByPID[currentParentPID] {
            if let terminalApp = recognizedTerminalApp(for: parent.command) {
                return terminalApp
            }

            currentParentPID = parent.parentPID
        }

        return nil
    }

    private func recognizedTerminalApp(for command: String) -> String? {
        let lowered = command.lowercased()

        if lowered.contains("/cmux.app/contents/macos/cmux") {
            return "cmux"
        }

        if lowered.contains("/ghostty.app/contents/macos/ghostty") || lowered.hasSuffix("/ghostty") {
            return "Ghostty"
        }

        if lowered.contains("/terminal.app/contents/macos/terminal") {
            return "Terminal"
        }

        if lowered.contains("/iterm.app/contents/macos/iterm2") {
            return "iTerm"
        }

        if lowered.contains("/kaku.app/contents/macos/kaku-gui") || lowered.hasSuffix("/kaku-gui") {
            return "Kaku"
        }

        if lowered.contains("/wezterm.app/contents/macos/wezterm-gui") || lowered.hasSuffix("/wezterm-gui") {
            return "WezTerm"
        }

        if lowered.contains("/warp.app/") || lowered.hasSuffix("/warp") {
            return "Warp"
        }

        if lowered.hasSuffix("/zellij") {
            return "Zellij"
        }

        // VS Code family
        if lowered.contains("/visual studio code.app/") || lowered.contains("/code helper") {
            return "VS Code"
        }
        if lowered.contains("/visual studio code - insiders.app/") {
            return "VS Code Insiders"
        }
        if lowered.contains("/cursor.app/") {
            return "Cursor"
        }
        if lowered.contains("/windsurf.app/") {
            return "Windsurf"
        }
        if lowered.contains("/trae.app/") {
            return "Trae"
        }

        // JetBrains IDEs
        if lowered.contains("/intellij idea.app/") || lowered.contains("/idea.app/") {
            return "IntelliJ IDEA"
        }
        if lowered.contains("/webstorm.app/") {
            return "WebStorm"
        }
        if lowered.contains("/pycharm.app/") {
            return "PyCharm"
        }
        if lowered.contains("/goland.app/") {
            return "GoLand"
        }
        if lowered.contains("/clion.app/") {
            return "CLion"
        }
        if lowered.contains("/rubymine.app/") {
            return "RubyMine"
        }
        if lowered.contains("/phpstorm.app/") {
            return "PhpStorm"
        }
        if lowered.contains("/rider.app/") {
            return "Rider"
        }
        if lowered.contains("/rustrover.app/") {
            return "RustRover"
        }

        return nil
    }

    private func lsofOutput(pid: String) -> String? {
        commandRunner("/usr/sbin/lsof", ["-a", "-p", pid, "-Fn"])
    }

    private func workingDirectory(from lsofOutput: String) -> String? {
        let lines = lsofOutput.split(whereSeparator: \.isNewline).map(String.init)
        for index in lines.indices {
            guard lines[index] == "fcwd",
                  lines.indices.contains(index + 1) else {
                continue
            }

            let nextLine = lines[index + 1]
            guard nextLine.first == "n" else {
                continue
            }

            let value = String(nextLine.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("/") {
                return value
            }
        }

        return nil
    }

    private func matchingPath(in lsofOutput: String, containing fragment: String, suffix: String) -> String? {
        for line in lsofOutput.split(whereSeparator: \.isNewline) {
            guard line.first == "n" else {
                continue
            }

            let value = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.contains(fragment), value.hasSuffix(suffix) else {
                continue
            }

            return value
        }

        return nil
    }

    private static let uuidRegex = try! NSRegularExpression(
        pattern: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
    )

    private func firstUUID(in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = Self.uuidRegex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }

        return String(text[matchRange]).lowercased()
    }

    private func claudeSessionID(from command: String) -> String? {
        sessionID(from: command, flags: ["--resume", "-r", "--session-id"])
    }

    private func sessionID(from command: String, flags: [String]) -> String? {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else {
            return nil
        }

        for index in tokens.indices {
            let token = tokens[index]

            if flags.contains(token) {
                let nextIndex = tokens.index(after: index)
                guard tokens.indices.contains(nextIndex) else {
                    continue
                }

                if let sessionID = firstUUID(in: tokens[nextIndex]) {
                    return sessionID
                }
            }

            for flag in flags where token.hasPrefix("\(flag)=") {
                let value = String(token.split(separator: "=", maxSplits: 1).last ?? "")
                if let sessionID = firstUUID(in: value) {
                    return sessionID
                }
            }
        }

        return nil
    }

    private func normalizedTTY(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "??" else {
            return nil
        }

        if trimmed.hasPrefix("/dev/") {
            return trimmed
        }

        return "/dev/\(trimmed)"
    }

    private func isCodexProcess(command: String) -> Bool {
        let lowered = command.lowercased()
        guard let firstToken = lowered.split(separator: " ").first.map(String.init) else {
            return false
        }

        return firstToken == "codex"
            || firstToken.hasSuffix("/codex")
            || lowered.contains("/codex/codex")
    }

    private func isOpenCodeProcess(command: String) -> Bool {
        let lowered = command.lowercased()
        return lowered.contains("/opencode-ai/") || lowered.contains("/opencode")
            || lowered.contains("/.opencode")
    }

    private func isPiProcess(command: String) -> Bool {
        let lowered = command.lowercased()
        guard let firstToken = lowered.split(separator: " ").first.map(String.init) else {
            return false
        }

        return firstToken == "pi"
            || firstToken.hasSuffix("/pi")
            || lowered.contains("/.pi/agent")
    }

    private func isClaudeProcess(command: String) -> Bool {
        let lowered = command.lowercased()
        if lowered.contains("/.local/bin/claude") {
            return true
        }

        guard let firstToken = lowered.split(separator: " ").first else {
            return false
        }

        return firstToken == "claude"
    }

    private static func commandOutput(executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        let completionGroup = DispatchGroup()
        completionGroup.enter()
        process.terminationHandler = { _ in
            completionGroup.leave()
        }
        let outputGroup = DispatchGroup()
        outputGroup.enter()
        let outputBox = OutputBox()
        DispatchQueue.global(qos: .utility).async {
            outputBox.data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }
        let timeout: TimeInterval = executablePath.hasSuffix("/lsof")
            ? Self.lsofCommandTimeout
            : Self.processCommandTimeout

        do {
            try process.run()
        } catch {
            return nil
        }

        let waitResult = completionGroup.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            process.terminate()
            _ = completionGroup.wait(timeout: .now() + 0.1)
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        _ = outputGroup.wait(timeout: .now() + 0.1)
        guard let output = String(data: outputBox.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return nil
        }

        return output
    }

    // MARK: - Tmux support

    private func resolveTmuxPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        // Fallback to 'which'
        guard let output = commandRunner("/usr/bin/which", ["tmux"]) else {
            return nil
        }

        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func resolveTmuxInfo(
        agentTTY: String,
        processes: [RunningProcess],
        processesByPID: [String: RunningProcess]
    ) -> (target: String, hostTerminalApp: String?, socketPath: String?)? {
        guard let tmuxPath = resolveTmuxPath() else {
            return nil
        }

        // Find tmux-server process to extract socket path if custom
        var socketPath: String? = nil
        for process in processes {
            if isTmuxServerProcess(command: process.command) {
                // Extract socket path from tmux-server command line
                let parts = process.command.split(separator: " ").map(String.init)
                for (index, part) in parts.enumerated() {
                    if (part == "-S" || part == "-L"), parts.indices.contains(index + 1) {
                        socketPath = String(parts[index + 1])
                        break
                    }
                }
                break
            }
        }

        // Query tmux list-panes to find the pane matching our TTY
        guard let tmuxTarget = queryTmuxTarget(agentTTY: agentTTY, tmuxPath: tmuxPath, socketPath: socketPath) else {
            return nil
        }

        // Find the terminal app hosting the tmux client connected to this pane
        guard let hostTerminalApp = findTmuxClientTerminal(tmuxPath: tmuxPath, socketPath: socketPath, processesByPID: processesByPID) else {
            return nil
        }

        return (tmuxTarget, hostTerminalApp, socketPath)
    }

    private func queryTmuxTarget(agentTTY: String, tmuxPath: String, socketPath: String?) -> String? {
        var args: [String] = ["list-panes", "-a", "-F", "#{pane_tty}\t#{session_name}:#{window_index}.#{pane_index}"]

        if let socketPath = socketPath {
            args = ["-S", socketPath] + args
        }

        guard let output = commandRunner(tmuxPath, args) else {
            return nil
        }

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                continue
            }

            let ptrTTY = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let target = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            if ptrTTY == agentTTY {
                return target
            }
        }

        return nil
    }

    private func findTmuxClientTerminal(
        tmuxPath: String,
        socketPath: String?,
        processesByPID: [String: RunningProcess]
    ) -> String? {
        var args: [String] = ["list-clients", "-F", "#{client_tty}"]

        if let socketPath = socketPath {
            args = ["-S", socketPath] + args
        }

        guard let output = commandRunner(tmuxPath, args) else {
            return nil
        }

        for clientTTYLine in output.split(separator: "\n") {
            let clientTTY = clientTTYLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clientTTY.isEmpty else {
                continue
            }

            // Find the process whose TTY matches this client TTY, then walk its parents
            for process in processesByPID.values {
                if process.terminalTTY == clientTTY {
                    if let terminalApp = terminalApp(for: process, processesByPID: processesByPID) {
                        return terminalApp
                    }
                }
            }
        }

        return nil
    }

    private func isTmuxServerProcess(command: String) -> Bool {
        let lowered = command.lowercased()
        return lowered.contains("tmux") && lowered.contains("new-session")
            || lowered.hasSuffix("tmux-server")
            || lowered.contains("tmux") && lowered.contains("server")
    }
}
