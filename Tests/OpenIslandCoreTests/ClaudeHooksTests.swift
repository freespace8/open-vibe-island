import Foundation
import Testing
@testable import OpenIslandCore

struct ClaudeHooksTests {
    @Test
    func claudeHookOutputEncoderEncodesPermissionDecision() throws {
        let output = try ClaudeHookOutputEncoder.standardOutput(
            for: .claudeHookDirective(
                .permissionRequest(
                    .deny(message: "Permission denied in Open Island.", interrupt: true)
                )
            )
        )

        let payload = try #require(output)
        let object = try jsonObject(from: payload)
        let hookSpecificOutput = object["hookSpecificOutput"] as? [String: Any]
        let decision = hookSpecificOutput?["decision"] as? [String: Any]

        #expect(hookSpecificOutput?["hookEventName"] as? String == "PermissionRequest")
        #expect(decision?["behavior"] as? String == "deny")
        #expect(decision?["message"] as? String == "Permission denied in Open Island.")
        #expect(decision?["interrupt"] as? Bool == true)
    }

    @Test
    func claudeHookInstallationManagerRoundTripsInstallAndUninstall() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-claude-hooks-\(UUID().uuidString)", isDirectory: true)
        let claudeDirectory = rootURL.appendingPathComponent(".claude", isDirectory: true)
        let manager = ClaudeHookInstallationManager(claudeDirectory: claudeDirectory)
        let hooksBinaryURL = rootURL.appendingPathComponent("OpenIslandHooks")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data().write(to: hooksBinaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooksBinaryURL.path)

        let installed = try manager.install(hooksBinaryURL: hooksBinaryURL)
        #expect(installed.managedHooksPresent)
        #expect(installed.manifest?.hookCommand == ClaudeHookInstaller.hookCommand(for: hooksBinaryURL.path))
        #expect(!installed.hasClaudeIslandHooks)

        let settingsObject = try jsonObject(from: Data(contentsOf: installed.settingsURL))
        let hooksObject = settingsObject["hooks"] as? [String: Any]
        #expect(hooksObject?["PermissionRequest"] != nil)
        #expect(hooksObject?["PreToolUse"] != nil)
        #expect(hooksObject?["UserPromptSubmit"] != nil)

        let reloaded = try manager.status(hooksBinaryURL: hooksBinaryURL)
        #expect(reloaded.managedHooksPresent)

        let uninstalled = try manager.uninstall()
        #expect(!uninstalled.managedHooksPresent)
        #expect(!FileManager.default.fileExists(atPath: uninstalled.manifestURL.path))
    }

    @Test
    func claudeTranscriptDiscoveryRecoversRecentSessions() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-claude-discovery-\(UUID().uuidString)", isDirectory: true)
        let workspaceDirectory = rootURL
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-tmp-demo-repo", isDirectory: true)
        let transcriptURL = workspaceDirectory
            .appendingPathComponent("session-123.jsonl")
        let discovery = ClaudeTranscriptDiscovery(rootURL: rootURL.appendingPathComponent("projects", isDirectory: true))

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        let transcript = """
        {"cwd":"/tmp/demo-repo","sessionId":"session-123","type":"user","message":{"role":"user","content":"Fix the flaky auth tests."},"timestamp":"2026-04-03T03:20:00Z"}
        {"cwd":"/tmp/demo-repo","sessionId":"session-123","type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"I’m checking the auth test setup now."},{"type":"tool_use","id":"toolu_1","name":"Glob","input":{"pattern":"**/*auth*.test.ts"}}]},"timestamp":"2026-04-03T03:20:02Z"}
        {"cwd":"/tmp/demo-repo","sessionId":"session-123","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"auth.test.ts"}]},"timestamp":"2026-04-03T03:20:04Z"}
        {"cwd":"/tmp/demo-repo","sessionId":"session-123","type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"Found the failing auth test file."}]},"timestamp":"2026-04-03T03:20:06Z"}
        """
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let sessions = discovery.discoverRecentSessions(
            now: ISO8601DateFormatter().date(from: "2026-04-03T03:20:10Z")!
        )

        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.id == "session-123")
        #expect(session.tool == .claudeCode)
        #expect(session.title == "Claude · demo-repo")
        #expect(session.summary == "Found the failing auth test file.")
        #expect(session.claudeMetadata?.initialUserPrompt == "Fix the flaky auth tests.")
        #expect(session.claudeMetadata?.lastAssistantMessage == "Found the failing auth test file.")
        #expect(session.claudeMetadata?.currentTool == nil)
        #expect(
            URL(fileURLWithPath: session.claudeMetadata?.transcriptPath ?? "").standardizedFileURL.path
                == transcriptURL.standardizedFileURL.path
        )
    }

    @Test
    func claudePermissionRequestReturnsAllowDirectiveAfterApproval() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = DemoBridgeServer(socketURL: socketURL, approvalTimeout: 5)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }
        try await observer.send(.registerClient(role: .observer))

        let toolInput: ClaudeHookJSONValue = .object(["command": .string("ls -la")])
        let preToolPayload = ClaudeHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .preToolUse,
            sessionID: "claude-session-1",
            toolName: "Bash",
            toolInput: toolInput,
            toolUseID: "tool-use-1"
        )
        let permissionPayload = ClaudeHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .permissionRequest,
            sessionID: "claude-session-1",
            toolName: "Bash",
            toolInput: toolInput
        )

        let preToolResponse = try BridgeCommandClient(socketURL: socketURL).send(.processClaudeHook(preToolPayload))
        #expect(preToolResponse == .acknowledged)

        let requestTask = Task {
            try BridgeCommandClient(socketURL: socketURL).send(.processClaudeHook(permissionPayload))
        }

        var iterator = stream.makeAsyncIterator()
        let permissionEvent = try await nextMatchingEvent(from: &iterator, maxEvents: 8) { event in
            if case .permissionRequested = event {
                return true
            }
            return false
        }

        if case let .permissionRequested(payload) = permissionEvent {
            #expect(payload.request.toolName == "Bash")
            #expect(payload.request.toolUseID == "tool-use-1")
            #expect(payload.request.primaryActionTitle == "Allow Once")
        } else {
            Issue.record("Expected a Claude permission request event")
        }

        try await observer.send(.resolvePermission(sessionID: "claude-session-1", resolution: .allowOnce()))

        let response = try await requestTask.value
        guard case let .some(.claudeHookDirective(.permissionRequest(.allow(updatedInput, updatedPermissions)))) = response else {
            Issue.record("Expected an allow directive for Claude permission request")
            return
        }

        #expect(updatedPermissions.isEmpty)
        #expect(updatedInput == toolInput)
    }

    @Test
    func claudeAskUserQuestionReturnsUpdatedAnswers() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = DemoBridgeServer(socketURL: socketURL, approvalTimeout: 5)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }
        try await observer.send(.registerClient(role: .observer))

        let questionToolInput: ClaudeHookJSONValue = .object([
            "questions": .array([
                .object([
                    "question": .string("Which environment?"),
                    "header": .string("Env"),
                    "options": .array([
                        option(label: "Production", description: "Use production"),
                        option(label: "Staging", description: "Use staging"),
                    ]),
                    "multiSelect": .boolean(false),
                ]),
                .object([
                    "question": .string("Which checks?"),
                    "header": .string("Checks"),
                    "options": .array([
                        option(label: "Unit tests", description: "Run unit tests"),
                        option(label: "Lint", description: "Run linter"),
                    ]),
                    "multiSelect": .boolean(true),
                ]),
            ]),
        ])

        let preToolPayload = ClaudeHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .preToolUse,
            sessionID: "claude-session-question",
            toolName: "AskUserQuestion",
            toolInput: questionToolInput,
            toolUseID: "tool-use-question"
        )
        let permissionPayload = ClaudeHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .permissionRequest,
            sessionID: "claude-session-question",
            toolName: "AskUserQuestion",
            toolInput: questionToolInput
        )

        _ = try BridgeCommandClient(socketURL: socketURL).send(.processClaudeHook(preToolPayload))

        let requestTask = Task {
            try BridgeCommandClient(socketURL: socketURL).send(.processClaudeHook(permissionPayload))
        }

        var iterator = stream.makeAsyncIterator()
        let questionEvent = try await nextMatchingEvent(from: &iterator, maxEvents: 8) { event in
            if case .questionAsked = event {
                return true
            }
            return false
        }

        if case let .questionAsked(payload) = questionEvent {
            #expect(payload.prompt.questions.count == 2)
            #expect(payload.prompt.questions.first?.header == "Env")
        } else {
            Issue.record("Expected a Claude AskUserQuestion event")
        }

        try await observer.send(
            .answerQuestion(
                sessionID: "claude-session-question",
                response: QuestionPromptResponse(
                    answers: [
                        "Which environment?": "Staging",
                        "Which checks?": "Lint, Unit tests",
                    ]
                )
            )
        )

        let response = try await requestTask.value
        guard case let .some(.claudeHookDirective(.permissionRequest(.allow(updatedInput, _)))) = response,
              case let .object(root)? = updatedInput,
              case let .object(answers)? = root["answers"] else {
            Issue.record("Expected AskUserQuestion answers to round-trip through updatedInput")
            return
        }

        #expect(answers["Which environment?"] == .string("Staging"))
        #expect(answers["Which checks?"] == .string("Lint, Unit tests"))
    }
}

private enum ClaudeHooksTestError: Error {
    case streamEnded
    case noMatchingEvent
}

private func nextEvent(
    from iterator: inout AsyncThrowingStream<AgentEvent, Error>.AsyncIterator
) async throws -> AgentEvent {
    guard let event = try await iterator.next() else {
        throw ClaudeHooksTestError.streamEnded
    }

    return event
}

private func nextMatchingEvent(
    from iterator: inout AsyncThrowingStream<AgentEvent, Error>.AsyncIterator,
    maxEvents: Int,
    predicate: (AgentEvent) -> Bool
) async throws -> AgentEvent {
    for _ in 0..<maxEvents {
        let event = try await nextEvent(from: &iterator)
        if predicate(event) {
            return event
        }
    }

    throw ClaudeHooksTestError.noMatchingEvent
}

private func jsonObject(from data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    return object as? [String: Any] ?? [:]
}

private func option(label: String, description: String) -> ClaudeHookJSONValue {
    .object([
        "label": .string(label),
        "description": .string(description),
    ])
}
