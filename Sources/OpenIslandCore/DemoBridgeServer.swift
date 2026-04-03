import Dispatch
import Darwin
import Foundation

public final class DemoBridgeServer: @unchecked Sendable {
    private struct ClientConnection {
        let id: UUID
        let fileDescriptor: Int32
        let readSource: DispatchSourceRead
        var role: BridgeClientRole?
        var buffer = Data()
    }

    private struct PendingApproval {
        let clientID: UUID
        let timeoutItem: DispatchWorkItem
    }

    private struct PendingClaudeToolContext {
        let toolUseID: String?
        let toolName: String?
        let toolInput: ClaudeHookJSONValue?
    }

    private struct PendingClaudeInteraction {
        enum Kind {
            case permission(ClaudeHookPayload)
            case question(ClaudeHookPayload, QuestionPrompt)
        }

        let clientID: UUID
        let timeoutItem: DispatchWorkItem
        let kind: Kind
    }

    private let socketURL: URL
    private let approvalTimeout: TimeInterval
    private let claudeInteractionTimeout: TimeInterval
    private let queue = DispatchQueue(label: "app.openisland.bridge.server")
    private let queueKey = DispatchSpecificKey<Void>()

    private var listeningFileDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [UUID: ClientConnection] = [:]
    private var pendingApprovals: [String: PendingApproval] = [:]
    private var pendingClaudeToolContexts: [String: PendingClaudeToolContext] = [:]
    private var pendingClaudeInteractions: [String: PendingClaudeInteraction] = [:]
    private var scheduledItems: [DispatchWorkItem] = []
    private var state = SessionState()

    public init(
        socketURL: URL = BridgeSocketLocation.defaultURL,
        approvalTimeout: TimeInterval = 45,
        claudeInteractionTimeout: TimeInterval = 24 * 60 * 60
    ) {
        self.socketURL = socketURL
        self.approvalTimeout = approvalTimeout
        self.claudeInteractionTimeout = claudeInteractionTimeout
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        stop()
    }

    public func start() throws {
        guard listeningFileDescriptor == -1 else {
            return
        }

        let parentURL = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: socketURL)

        let listeningFileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listeningFileDescriptor != -1 else {
            throw BridgeTransportError.systemCallFailed("socket", errno)
        }

        do {
            var reuseAddress: Int32 = 1
            guard setsockopt(
                listeningFileDescriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuseAddress,
                socklen_t(MemoryLayout<Int32>.size)
            ) != -1 else {
                throw BridgeTransportError.systemCallFailed("setsockopt", errno)
            }

            try withUnixSocketAddress(path: socketURL.path) { address, length in
                guard bind(listeningFileDescriptor, address, length) != -1 else {
                    throw BridgeTransportError.systemCallFailed("bind", errno)
                }
            }

            guard listen(listeningFileDescriptor, 16) != -1 else {
                throw BridgeTransportError.systemCallFailed("listen", errno)
            }

            try makeSocketNonBlocking(listeningFileDescriptor)
        } catch {
            close(listeningFileDescriptor)
            try? FileManager.default.removeItem(at: socketURL)
            throw error
        }

        self.listeningFileDescriptor = listeningFileDescriptor

        let acceptSource = DispatchSource.makeReadSource(fileDescriptor: listeningFileDescriptor, queue: queue)
        acceptSource.setEventHandler { [weak self] in
            self?.acceptPendingClients()
        }
        acceptSource.setCancelHandler { [weak self] in
            guard let self else {
                return
            }

            if self.listeningFileDescriptor != -1 {
                close(self.listeningFileDescriptor)
                self.listeningFileDescriptor = -1
            }
        }
        self.acceptSource = acceptSource
        acceptSource.resume()
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopLocked()
        } else {
            queue.sync {
                stopLocked()
            }
        }
    }

    private func stopLocked() {
        scheduledItems.forEach { $0.cancel() }
        scheduledItems.removeAll()

        pendingApprovals.values.forEach { $0.timeoutItem.cancel() }
        pendingApprovals.removeAll()
        pendingClaudeInteractions.values.forEach { $0.timeoutItem.cancel() }
        pendingClaudeInteractions.removeAll()
        pendingClaudeToolContexts.removeAll()

        let activeConnections = Array(clients.values)
        activeConnections.forEach { $0.readSource.cancel() }
        clients.removeAll()

        acceptSource?.cancel()
        acceptSource = nil

        if listeningFileDescriptor != -1 {
            close(listeningFileDescriptor)
            listeningFileDescriptor = -1
        }

        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptPendingClients() {
        guard listeningFileDescriptor != -1 else {
            return
        }

        while true {
            let clientFileDescriptor = accept(listeningFileDescriptor, nil, nil)

            if clientFileDescriptor == -1 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }

                return
            }

            do {
                try disableSocketSigPipe(clientFileDescriptor)
                try makeSocketNonBlocking(clientFileDescriptor)
                configureClient(fileDescriptor: clientFileDescriptor)
            } catch {
                close(clientFileDescriptor)
            }
        }
    }

    private func configureClient(fileDescriptor: Int32) {
        let clientID = UUID()
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)

        readSource.setEventHandler { [weak self] in
            self?.readAvailableData(from: clientID)
        }
        readSource.setCancelHandler { [weak self] in
            guard let self else {
                return
            }

            if let client = self.clients[clientID] {
                close(client.fileDescriptor)
            } else {
                close(fileDescriptor)
            }
        }

        clients[clientID] = ClientConnection(
            id: clientID,
            fileDescriptor: fileDescriptor,
            readSource: readSource,
            role: nil
        )
        readSource.resume()

        send(.hello(BridgeHello()), to: clientID)
    }

    private func readAvailableData(from clientID: UUID) {
        guard var client = clients[clientID] else {
            return
        }

        var localBuffer = [UInt8](repeating: 0, count: 8_192)

        while true {
            let bytesRead = read(client.fileDescriptor, &localBuffer, localBuffer.count)

            if bytesRead > 0 {
                client.buffer.append(localBuffer, count: bytesRead)

                do {
                    let envelopes = try BridgeCodec.decodeLines(from: &client.buffer)
                    clients[clientID] = client

                    for envelope in envelopes {
                        if case let .command(command) = envelope {
                            handle(command, from: clientID)
                        }
                    }
                } catch {
                    removeClient(clientID)
                    return
                }

                continue
            }

            if bytesRead == 0 {
                removeClient(clientID)
                return
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                clients[clientID] = client
                return
            }

            removeClient(clientID)
            return
        }
    }

    private func handle(_ command: BridgeCommand, from clientID: UUID) {
        switch command {
        case let .registerClient(role):
            guard var client = clients[clientID] else {
                return
            }

            client.role = role
            clients[clientID] = client
            send(.response(.acknowledged), to: clientID)

        case let .requestQuestion(sessionID, prompt):
            guard state.session(id: sessionID) != nil else {
                send(.response(.acknowledged), to: clientID)
                return
            }

            emit(
                .questionAsked(
                    QuestionAsked(
                        sessionID: sessionID,
                        prompt: prompt,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case let .resolvePermission(sessionID, resolution):
            if pendingClaudeInteractions[sessionID] != nil {
                resolvePendingClaudeInteraction(sessionID: sessionID, resolution: resolution)
                send(.response(.acknowledged), to: clientID)
                return
            }

            let hasPendingHook = pendingApprovals[sessionID] != nil
            let event: AgentEvent

            if resolution.isApproved {
                event = .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: sessionID,
                        summary: hasPendingHook
                            ? "Permission approved. Codex continued the command."
                            : "Permission approved. Agent resumed work.",
                        phase: .running,
                        timestamp: .now
                    )
                )

                if !hasPendingHook {
                    schedule(
                        event: .sessionCompleted(
                            SessionCompleted(
                                sessionID: sessionID,
                                summary: "Auth middleware patch applied after approval.",
                                timestamp: .now.addingTimeInterval(4)
                            )
                        ),
                        after: 4
                    )
                }
            } else {
                event = .sessionCompleted(
                    SessionCompleted(
                        sessionID: sessionID,
                        summary: hasPendingHook
                            ? "Permission denied in Open Island."
                            : "Permission denied. Review the session in the terminal.",
                        timestamp: .now
                    )
                )
            }

            emit(event)
            resolvePendingApproval(sessionID: sessionID, approved: resolution.isApproved)
            send(.response(.acknowledged), to: clientID)

        case let .answerQuestion(sessionID, response):
            if pendingClaudeInteractions[sessionID] != nil {
                resolvePendingClaudeQuestion(sessionID: sessionID, response: response)
                send(.response(.acknowledged), to: clientID)
                return
            }

            let resumeEvent = AgentEvent.activityUpdated(
                SessionActivityUpdated(
                    sessionID: sessionID,
                    summary: "Answered: \(response.displaySummary)",
                    phase: .running,
                    timestamp: .now
                )
            )

            emit(resumeEvent)
            schedule(
                event: .sessionCompleted(
                    SessionCompleted(
                        sessionID: sessionID,
                        summary: "Slow query analysis finished after targeting \(response.displaySummary.lowercased()).",
                        timestamp: .now.addingTimeInterval(4)
                    )
                ),
                after: 4
            )
            send(.response(.acknowledged), to: clientID)

        case let .processCodexHook(payload):
            handleCodexHook(payload, from: clientID)

        case let .processClaudeHook(payload):
            handleClaudeHook(payload, from: clientID)
        }
    }

    private func handleCodexHook(_ payload: CodexHookPayload, from clientID: UUID) {
        switch payload.hookEventName {
        case .sessionStart:
            let event = AgentEvent.sessionStarted(
                SessionStarted(
                    sessionID: payload.sessionID,
                    title: payload.sessionTitle,
                    tool: .codex,
                    origin: .live,
                    summary: payload.implicitStartSummary,
                    timestamp: .now,
                    jumpTarget: payload.defaultJumpTarget,
                    codexMetadata: payload.defaultCodexMetadata.isEmpty ? nil : payload.defaultCodexMetadata
                )
            )

            emit(event)
            send(.response(.acknowledged), to: clientID)

        case .userPromptSubmit:
            ensureSessionExists(for: payload)
            synchronizeJumpTarget(for: payload)
            synchronizeCodexMetadata(for: payload)
            let prompt = payload.promptPreview ?? "User submitted a prompt to Codex."
            emit(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: payload.sessionID,
                        summary: "Prompt: \(prompt)",
                        phase: .running,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .preToolUse:
            ensureSessionExists(for: payload)
            synchronizeJumpTarget(for: payload)
            synchronizeCodexMetadata(for: payload)

            let command = payload.commandPreview ?? "Bash command"
            guard !payload.permissionMode.bypassesIslandApproval else {
                emit(
                    .activityUpdated(
                        SessionActivityUpdated(
                            sessionID: payload.sessionID,
                            summary: "Running Bash without approval: \(command)",
                            phase: .running,
                            timestamp: .now
                        )
                    )
                )
                send(.response(.acknowledged), to: clientID)
                return
            }

            guard hasApprovalObserver(excluding: clientID) else {
                emit(
                    .activityUpdated(
                        SessionActivityUpdated(
                            sessionID: payload.sessionID,
                            summary: "Running Bash: \(command)",
                            phase: .running,
                            timestamp: .now
                        )
                    )
                )
                send(.response(.acknowledged), to: clientID)
                return
            }

            pendingApprovals[payload.sessionID]?.timeoutItem.cancel()

            let approvalEvent = AgentEvent.permissionRequested(
                PermissionRequested(
                    sessionID: payload.sessionID,
                    request: PermissionRequest(
                        title: "Run Bash command",
                        summary: "Codex wants to run a shell command.",
                        affectedPath: payload.commandText ?? command,
                        primaryActionTitle: "Allow",
                        secondaryActionTitle: "Deny"
                    ),
                    timestamp: .now
                )
            )

            emit(approvalEvent)

            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.resolveTimedOutApproval(
                    sessionID: payload.sessionID,
                    commandPreview: command
                )
            }

            pendingApprovals[payload.sessionID] = PendingApproval(
                clientID: clientID,
                timeoutItem: timeoutItem
            )
            queue.asyncAfter(deadline: .now() + approvalTimeout, execute: timeoutItem)

        case .postToolUse:
            ensureSessionExists(for: payload)
            synchronizeJumpTarget(for: payload)
            synchronizeCodexMetadata(for: payload)
            let command = payload.commandPreview ?? "Bash command"
            let responsePreview = payload.toolResponsePreview
            let summary = responsePreview.map { "Bash finished: \(command) · \($0)" } ?? "Bash finished: \(command)"

            emit(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: payload.sessionID,
                        summary: summary,
                        phase: .running,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .stop:
            ensureSessionExists(for: payload)
            synchronizeJumpTarget(for: payload)
            synchronizeCodexMetadata(for: payload)
            let summary = payload.assistantMessagePreview ?? "Codex completed the turn."

            emit(
                .sessionCompleted(
                    SessionCompleted(
                        sessionID: payload.sessionID,
                        summary: summary,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)
        }
    }

    private func handleClaudeHook(_ payload: ClaudeHookPayload, from clientID: UUID) {
        switch payload.hookEventName {
        case .sessionStart:
            emit(
                .sessionStarted(
                    SessionStarted(
                        sessionID: payload.sessionID,
                        title: payload.sessionTitle,
                        tool: .claudeCode,
                        origin: .live,
                        summary: payload.implicitStartSummary,
                        timestamp: .now,
                        jumpTarget: payload.defaultJumpTarget,
                        claudeMetadata: payload.defaultClaudeMetadata.isEmpty ? nil : payload.defaultClaudeMetadata
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .userPromptSubmit:
            ensureClaudeSessionExists(for: payload)
            synchronizeClaudeJumpTarget(for: payload)
            synchronizeClaudeMetadata(for: payload)
            emit(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: payload.sessionID,
                        summary: payload.promptPreview.map { "Prompt: \($0)" } ?? payload.implicitStartSummary,
                        phase: .running,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .preToolUse:
            ensureClaudeSessionExists(for: payload)
            synchronizeClaudeJumpTarget(for: payload)
            synchronizeClaudeMetadata(for: payload)
            pendingClaudeToolContexts[payload.permissionCorrelationKey] = PendingClaudeToolContext(
                toolUseID: payload.toolUseID,
                toolName: payload.toolName,
                toolInput: payload.toolInput
            )

            let summary = payload.toolName.map { "Running \($0)" } ?? "Running Claude tool"
            emit(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: payload.sessionID,
                        summary: payload.toolInputPreview.map { "\(summary): \($0)" } ?? summary,
                        phase: .running,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .permissionRequest:
            ensureClaudeSessionExists(for: payload)
            synchronizeClaudeJumpTarget(for: payload)
            synchronizeClaudeMetadata(for: payload)

            pendingClaudeInteractions[payload.sessionID]?.timeoutItem.cancel()

            if let prompt = payload.questionPrompt {
                emit(
                    .questionAsked(
                        QuestionAsked(
                            sessionID: payload.sessionID,
                            prompt: prompt,
                            timestamp: .now
                        )
                    )
                )

                let timeoutItem = DispatchWorkItem { [weak self] in
                    self?.resolveTimedOutClaudeQuestion(sessionID: payload.sessionID)
                }

                pendingClaudeInteractions[payload.sessionID] = PendingClaudeInteraction(
                    clientID: clientID,
                    timeoutItem: timeoutItem,
                    kind: .question(payload, prompt)
                )
                queue.asyncAfter(deadline: .now() + claudeInteractionTimeout, execute: timeoutItem)
            } else {
                emit(
                    .permissionRequested(
                        PermissionRequested(
                            sessionID: payload.sessionID,
                            request: PermissionRequest(
                                title: payload.permissionRequestTitle,
                                summary: payload.permissionRequestSummary,
                                affectedPath: payload.permissionAffectedPath,
                                primaryActionTitle: "Allow Once",
                                secondaryActionTitle: "Deny",
                                toolName: payload.toolName,
                                toolUseID: claudeToolUseID(for: payload),
                                suggestedUpdates: payload.permissionSuggestions ?? []
                            ),
                            timestamp: .now
                        )
                    )
                )

                let timeoutItem = DispatchWorkItem { [weak self] in
                    self?.resolveTimedOutClaudePermission(sessionID: payload.sessionID, payload: payload)
                }

                pendingClaudeInteractions[payload.sessionID] = PendingClaudeInteraction(
                    clientID: clientID,
                    timeoutItem: timeoutItem,
                    kind: .permission(payload)
                )
                queue.asyncAfter(deadline: .now() + claudeInteractionTimeout, execute: timeoutItem)
            }

        case .postToolUse:
            ensureClaudeSessionExists(for: payload)
            synchronizeClaudeJumpTarget(for: payload)
            synchronizeClaudeMetadata(for: payload)
            pendingClaudeToolContexts.removeValue(forKey: payload.permissionCorrelationKey)

            let summary = {
                if payload.toolName == "AskUserQuestion" {
                    return "Claude captured your answers."
                }

                if let preview = payload.toolResponsePreview,
                   let toolName = payload.toolName {
                    return "\(toolName) finished: \(preview)"
                }

                if let toolName = payload.toolName {
                    return "\(toolName) finished."
                }

                return payload.implicitStartSummary
            }()

            emit(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: payload.sessionID,
                        summary: summary,
                        phase: .running,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .postToolUseFailure:
            ensureClaudeSessionExists(for: payload)
            synchronizeClaudeJumpTarget(for: payload)
            synchronizeClaudeMetadata(for: payload)
            pendingClaudeToolContexts.removeValue(forKey: payload.permissionCorrelationKey)

            emit(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: payload.sessionID,
                        summary: payload.error ?? "Claude tool failed.",
                        phase: payload.isInterrupt == true ? .completed : .running,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .permissionDenied:
            ensureClaudeSessionExists(for: payload)
            synchronizeClaudeJumpTarget(for: payload)
            synchronizeClaudeMetadata(for: payload)

            emit(
                .sessionCompleted(
                    SessionCompleted(
                        sessionID: payload.sessionID,
                        summary: payload.error ?? "Claude permission was denied.",
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .notification:
            ensureClaudeSessionExists(for: payload)
            synchronizeClaudeJumpTarget(for: payload)
            synchronizeClaudeMetadata(for: payload)

            emit(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: payload.sessionID,
                        summary: payload.notificationPreview ?? payload.implicitStartSummary,
                        phase: .running,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .stop:
            ensureClaudeSessionExists(for: payload)
            synchronizeClaudeJumpTarget(for: payload)
            synchronizeClaudeMetadata(for: payload)

            emit(
                .sessionCompleted(
                    SessionCompleted(
                        sessionID: payload.sessionID,
                        summary: payload.assistantMessagePreview ?? "Claude completed the turn.",
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .stopFailure:
            ensureClaudeSessionExists(for: payload)
            synchronizeClaudeJumpTarget(for: payload)
            synchronizeClaudeMetadata(for: payload)

            emit(
                .sessionCompleted(
                    SessionCompleted(
                        sessionID: payload.sessionID,
                        summary: payload.error ?? payload.assistantMessagePreview ?? "Claude failed to finish the turn.",
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .subagentStart:
            ensureClaudeSessionExists(for: payload)
            synchronizeClaudeJumpTarget(for: payload)
            synchronizeClaudeMetadata(for: payload)

            let summary = payload.agentType.map { "Started \($0) subagent." } ?? "Started Claude subagent."
            emit(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: payload.sessionID,
                        summary: summary,
                        phase: .running,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .subagentStop:
            ensureClaudeSessionExists(for: payload)
            synchronizeClaudeJumpTarget(for: payload)
            synchronizeClaudeMetadata(for: payload)

            let summary = payload.assistantMessagePreview
                ?? payload.agentType.map { "Finished \($0) subagent." }
                ?? "Finished Claude subagent."
            emit(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: payload.sessionID,
                        summary: summary,
                        phase: .running,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .preCompact:
            ensureClaudeSessionExists(for: payload)
            synchronizeClaudeJumpTarget(for: payload)
            synchronizeClaudeMetadata(for: payload)

            emit(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: payload.sessionID,
                        summary: "Claude is compacting the conversation.",
                        phase: .running,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .sessionEnd:
            ensureClaudeSessionExists(for: payload)
            synchronizeClaudeJumpTarget(for: payload)
            synchronizeClaudeMetadata(for: payload)

            emit(
                .sessionCompleted(
                    SessionCompleted(
                        sessionID: payload.sessionID,
                        summary: "Claude session ended.",
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)
        }
    }

    private func hasApprovalObserver(excluding clientID: UUID) -> Bool {
        if clients.values.contains(where: { $0.id != clientID && $0.role == .observer }) {
            return true
        }

        return clients.values.contains(where: { $0.id != clientID })
    }

    private func ensureSessionExists(for payload: CodexHookPayload) {
        guard state.session(id: payload.sessionID) == nil else {
            return
        }

        emit(
            .sessionStarted(
                SessionStarted(
                    sessionID: payload.sessionID,
                    title: payload.sessionTitle,
                    tool: .codex,
                    origin: .live,
                    summary: payload.implicitStartSummary,
                    timestamp: .now,
                    jumpTarget: payload.defaultJumpTarget,
                    codexMetadata: payload.defaultCodexMetadata.isEmpty ? nil : payload.defaultCodexMetadata
                )
            )
        )
    }

    private func synchronizeJumpTarget(for payload: CodexHookPayload) {
        guard let existingSession = state.session(id: payload.sessionID) else {
            return
        }

        let jumpTarget = payload.defaultJumpTarget
        guard existingSession.jumpTarget != jumpTarget else {
            return
        }

        emit(
            .jumpTargetUpdated(
                JumpTargetUpdated(
                    sessionID: payload.sessionID,
                    jumpTarget: jumpTarget,
                    timestamp: .now
                )
            )
        )
    }

    private func synchronizeCodexMetadata(for payload: CodexHookPayload) {
        guard let existingSession = state.session(id: payload.sessionID) else {
            return
        }

        let mergedMetadata = mergedCodexMetadata(
            existing: existingSession.codexMetadata,
            update: payload.defaultCodexMetadata,
            hookEventName: payload.hookEventName
        )
        guard !mergedMetadata.isEmpty else {
            return
        }

        guard existingSession.codexMetadata != mergedMetadata else {
            return
        }

        emit(
            .sessionMetadataUpdated(
                SessionMetadataUpdated(
                    sessionID: payload.sessionID,
                    codexMetadata: mergedMetadata,
                    timestamp: .now
                )
            )
        )
    }

    private func ensureClaudeSessionExists(for payload: ClaudeHookPayload) {
        guard state.session(id: payload.sessionID) == nil else {
            return
        }

        emit(
            .sessionStarted(
                SessionStarted(
                    sessionID: payload.sessionID,
                    title: payload.sessionTitle,
                    tool: .claudeCode,
                    origin: .live,
                    summary: payload.implicitStartSummary,
                    timestamp: .now,
                    jumpTarget: payload.defaultJumpTarget,
                    claudeMetadata: payload.defaultClaudeMetadata.isEmpty ? nil : payload.defaultClaudeMetadata
                )
            )
        )
    }

    private func synchronizeClaudeJumpTarget(for payload: ClaudeHookPayload) {
        guard let existingSession = state.session(id: payload.sessionID) else {
            return
        }

        let jumpTarget = payload.defaultJumpTarget
        guard existingSession.jumpTarget != jumpTarget else {
            return
        }

        emit(
            .jumpTargetUpdated(
                JumpTargetUpdated(
                    sessionID: payload.sessionID,
                    jumpTarget: jumpTarget,
                    timestamp: .now
                )
            )
        )
    }

    private func synchronizeClaudeMetadata(for payload: ClaudeHookPayload) {
        guard let existingSession = state.session(id: payload.sessionID) else {
            return
        }

        let mergedMetadata = mergedClaudeMetadata(
            existing: existingSession.claudeMetadata,
            update: payload.defaultClaudeMetadata,
            hookEventName: payload.hookEventName
        )
        guard !mergedMetadata.isEmpty else {
            return
        }

        guard existingSession.claudeMetadata != mergedMetadata else {
            return
        }

        emit(
            .claudeSessionMetadataUpdated(
                ClaudeSessionMetadataUpdated(
                    sessionID: payload.sessionID,
                    claudeMetadata: mergedMetadata,
                    timestamp: .now
                )
            )
        )
    }

    private func mergedCodexMetadata(
        existing: CodexSessionMetadata?,
        update: CodexSessionMetadata,
        hookEventName: CodexHookEventName
    ) -> CodexSessionMetadata {
        CodexSessionMetadata(
            transcriptPath: update.transcriptPath ?? existing?.transcriptPath,
            initialUserPrompt: existing?.initialUserPrompt ?? update.initialUserPrompt ?? update.lastUserPrompt,
            lastUserPrompt: update.lastUserPrompt ?? existing?.lastUserPrompt,
            lastAssistantMessage: update.lastAssistantMessage ?? existing?.lastAssistantMessage,
            currentTool: mergedCurrentTool(
                existing: existing?.currentTool,
                update: update.currentTool,
                hookEventName: hookEventName
            ),
            currentCommandPreview: mergedCurrentCommandPreview(
                existing: existing?.currentCommandPreview,
                update: update.currentCommandPreview,
                hookEventName: hookEventName
            )
        )
    }

    private func mergedCurrentTool(
        existing: String?,
        update: String?,
        hookEventName: CodexHookEventName
    ) -> String? {
        if let update {
            return update
        }

        switch hookEventName {
        case .userPromptSubmit, .postToolUse, .stop:
            return nil
        case .sessionStart, .preToolUse:
            return existing
        }
    }

    private func mergedClaudeMetadata(
        existing: ClaudeSessionMetadata?,
        update: ClaudeSessionMetadata,
        hookEventName: ClaudeHookEventName
    ) -> ClaudeSessionMetadata {
        ClaudeSessionMetadata(
            transcriptPath: update.transcriptPath ?? existing?.transcriptPath,
            initialUserPrompt: existing?.initialUserPrompt ?? update.initialUserPrompt ?? update.lastUserPrompt,
            lastUserPrompt: update.lastUserPrompt ?? existing?.lastUserPrompt,
            lastAssistantMessage: update.lastAssistantMessage ?? existing?.lastAssistantMessage,
            currentTool: mergedClaudeCurrentTool(
                existing: existing?.currentTool,
                update: update.currentTool,
                hookEventName: hookEventName
            ),
            currentToolInputPreview: mergedClaudeCurrentToolInputPreview(
                existing: existing?.currentToolInputPreview,
                update: update.currentToolInputPreview,
                hookEventName: hookEventName
            ),
            model: update.model ?? existing?.model,
            startupSource: update.startupSource ?? existing?.startupSource,
            permissionMode: update.permissionMode ?? existing?.permissionMode,
            agentID: update.agentID ?? existing?.agentID,
            agentType: update.agentType ?? existing?.agentType
        )
    }

    private func mergedClaudeCurrentTool(
        existing: String?,
        update: String?,
        hookEventName: ClaudeHookEventName
    ) -> String? {
        if let update {
            return update
        }

        switch hookEventName {
        case .postToolUse, .postToolUseFailure, .permissionDenied, .stop, .stopFailure, .sessionEnd:
            return nil
        case .sessionStart, .userPromptSubmit, .preToolUse, .permissionRequest, .notification, .subagentStart, .subagentStop, .preCompact:
            return existing
        }
    }

    private func mergedClaudeCurrentToolInputPreview(
        existing: String?,
        update: String?,
        hookEventName: ClaudeHookEventName
    ) -> String? {
        if let update {
            return update
        }

        switch hookEventName {
        case .postToolUse, .postToolUseFailure, .permissionDenied, .stop, .stopFailure, .sessionEnd:
            return nil
        case .sessionStart, .userPromptSubmit, .preToolUse, .permissionRequest, .notification, .subagentStart, .subagentStop, .preCompact:
            return existing
        }
    }

    private func mergedCurrentCommandPreview(
        existing: String?,
        update: String?,
        hookEventName: CodexHookEventName
    ) -> String? {
        if let update {
            return update
        }

        switch hookEventName {
        case .userPromptSubmit, .postToolUse, .stop:
            return nil
        case .sessionStart, .preToolUse:
            return existing
        }
    }

    private func resolvePendingApproval(sessionID: String, approved: Bool) {
        guard let pendingApproval = pendingApprovals.removeValue(forKey: sessionID) else {
            return
        }

        pendingApproval.timeoutItem.cancel()

        let response: BridgeResponse
        if approved {
            response = .acknowledged
        } else {
            response = .codexHookDirective(.deny(reason: "Permission denied in Open Island."))
        }

        send(.response(response), to: pendingApproval.clientID)
    }

    private func resolvePendingClaudeInteraction(
        sessionID: String,
        resolution: PermissionResolution
    ) {
        guard let pendingInteraction = pendingClaudeInteractions.removeValue(forKey: sessionID) else {
            return
        }

        pendingInteraction.timeoutItem.cancel()

        let directive: ClaudeHookDirective
        let summary: String
        let phase: SessionPhase

        switch (pendingInteraction.kind, resolution) {
        case let (.permission(payload), .allowOnce(updatedInput, updatedPermissions)):
            let finalInput = updatedInput ?? payload.toolInput
            directive = .permissionRequest(
                .allow(updatedInput: finalInput, updatedPermissions: updatedPermissions)
            )
            summary = payload.toolName.map { "Permission approved for \($0)." } ?? "Permission approved."
            phase = .running

        case let (.permission(_), .deny(message, interrupt)):
            directive = .permissionRequest(
                .deny(message: message ?? "Permission denied in Open Island.", interrupt: interrupt)
            )
            summary = message ?? "Permission denied in Open Island."
            phase = .completed

        case let (.question(payload, _), .allowOnce(updatedInput, updatedPermissions)):
            let finalInput = updatedInput ?? payload.toolInput
            directive = .permissionRequest(
                .allow(updatedInput: finalInput, updatedPermissions: updatedPermissions)
            )
            summary = "Claude's questions were answered."
            phase = .running

        case let (.question(_, _), .deny(message, interrupt)):
            directive = .permissionRequest(
                .deny(message: message ?? "Declined to answer Claude's questions.", interrupt: interrupt)
            )
            summary = message ?? "Declined to answer Claude's questions."
            phase = .completed
        }

        emit(
            phase == .completed
                ? .sessionCompleted(
                    SessionCompleted(
                        sessionID: sessionID,
                        summary: summary,
                        timestamp: .now
                    )
                )
                : .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: sessionID,
                        summary: summary,
                        phase: phase,
                        timestamp: .now
                    )
                )
        )

        send(.response(.claudeHookDirective(directive)), to: pendingInteraction.clientID)
    }

    private func resolvePendingClaudeQuestion(
        sessionID: String,
        response: QuestionPromptResponse
    ) {
        guard let pendingInteraction = pendingClaudeInteractions.removeValue(forKey: sessionID) else {
            return
        }

        pendingInteraction.timeoutItem.cancel()

        guard case let .question(payload, prompt) = pendingInteraction.kind else {
            return
        }

        let updatedInput = mergedClaudeQuestionInput(
            payload: payload,
            prompt: prompt,
            response: response
        )
        let summary = response.displaySummary.isEmpty
            ? "Answered Claude's questions."
            : "Answered: \(response.displaySummary)"

        emit(
            .activityUpdated(
                SessionActivityUpdated(
                    sessionID: sessionID,
                    summary: summary,
                    phase: .running,
                    timestamp: .now
                )
            )
        )

        send(
            .response(
                .claudeHookDirective(
                    .permissionRequest(.allow(updatedInput: updatedInput))
                )
            ),
            to: pendingInteraction.clientID
        )
    }

    private func resolveTimedOutApproval(sessionID: String, commandPreview: String) {
        guard let pendingApproval = pendingApprovals.removeValue(forKey: sessionID) else {
            return
        }

        emit(
            .activityUpdated(
                SessionActivityUpdated(
                    sessionID: sessionID,
                    summary: "Approval timed out. Codex continued Bash: \(commandPreview)",
                    phase: .running,
                    timestamp: .now
                )
            )
        )

        send(.response(.acknowledged), to: pendingApproval.clientID)
    }

    private func resolveTimedOutClaudePermission(
        sessionID: String,
        payload: ClaudeHookPayload
    ) {
        guard let pendingInteraction = pendingClaudeInteractions.removeValue(forKey: sessionID) else {
            return
        }

        emit(
            .sessionCompleted(
                SessionCompleted(
                    sessionID: sessionID,
                    summary: "Permission request timed out for \(payload.toolName ?? "Claude tool").",
                    timestamp: .now
                )
            )
        )

        send(
            .response(
                .claudeHookDirective(
                    .permissionRequest(
                        .deny(message: "Permission request timed out in Open Island.", interrupt: true)
                    )
                )
            ),
            to: pendingInteraction.clientID
        )
    }

    private func resolveTimedOutClaudeQuestion(sessionID: String) {
        guard let pendingInteraction = pendingClaudeInteractions.removeValue(forKey: sessionID) else {
            return
        }

        emit(
            .sessionCompleted(
                SessionCompleted(
                    sessionID: sessionID,
                    summary: "Claude's question timed out in Open Island.",
                    timestamp: .now
                )
            )
        )

        send(
            .response(
                .claudeHookDirective(
                    .permissionRequest(
                        .deny(message: "Claude's question timed out in Open Island.", interrupt: true)
                    )
                )
            ),
            to: pendingInteraction.clientID
        )
    }

    private func claudeToolUseID(for payload: ClaudeHookPayload) -> String? {
        payload.toolUseID ?? pendingClaudeToolContexts[payload.permissionCorrelationKey]?.toolUseID
    }

    private func mergedClaudeQuestionInput(
        payload: ClaudeHookPayload,
        prompt: QuestionPrompt,
        response: QuestionPromptResponse
    ) -> ClaudeHookJSONValue {
        let fallbackQuestion = prompt.questions.first?.question

        var answers = response.answers
        if answers.isEmpty,
           let rawAnswer = response.rawAnswer,
           !rawAnswer.isEmpty,
           let fallbackQuestion {
            answers[fallbackQuestion] = rawAnswer
        }

        var annotationsObject: [String: ClaudeHookJSONValue] = [:]
        for key in response.annotations.keys.sorted() {
            guard let annotation = response.annotations[key] else {
                continue
            }

            var object: [String: ClaudeHookJSONValue] = [:]
            if let preview = annotation.preview, !preview.isEmpty {
                object["preview"] = .string(preview)
            }
            if let notes = annotation.notes, !notes.isEmpty {
                object["notes"] = .string(notes)
            }
            if !object.isEmpty {
                annotationsObject[key] = .object(object)
            }
        }

        guard case let .object(existingObject) = payload.toolInput else {
            return .object([
                "answers": .object(answers.mapValues { .string($0) }),
                "annotations": .object(annotationsObject),
            ])
        }

        var updatedObject = existingObject
        updatedObject["answers"] = .object(answers.mapValues { .string($0) })
        if !annotationsObject.isEmpty {
            updatedObject["annotations"] = .object(annotationsObject)
        }

        return .object(updatedObject)
    }

    private func emit(_ event: AgentEvent) {
        state.apply(event)
        broadcast([.event(event)])
    }

    private func schedule(event: AgentEvent, after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            self?.emit(event)
        }

        scheduledItems.append(item)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func send(_ envelope: BridgeEnvelope, to clientID: UUID) {
        guard let client = clients[clientID] else {
            return
        }

        do {
            let data = try BridgeCodec.encodeLine(envelope)
            try writeAll(data, to: client.fileDescriptor)
        } catch {
            removeClient(clientID)
        }
    }

    private func broadcast(_ envelopes: [BridgeEnvelope]) {
        let clientIDs = Array(clients.keys)

        for clientID in clientIDs {
            for envelope in envelopes {
                send(envelope, to: clientID)
            }
        }
    }

    private func removeClient(_ clientID: UUID) {
        guard let client = clients.removeValue(forKey: clientID) else {
            return
        }

        let pendingSessionIDs = pendingApprovals.compactMap { entry -> String? in
            let (sessionID, pendingApproval) = entry
            return pendingApproval.clientID == clientID ? sessionID : nil
        }

        for sessionID in pendingSessionIDs {
            pendingApprovals[sessionID]?.timeoutItem.cancel()
            pendingApprovals.removeValue(forKey: sessionID)
        }

        let pendingClaudeSessionIDs = pendingClaudeInteractions.compactMap { entry -> String? in
            let (sessionID, pendingInteraction) = entry
            return pendingInteraction.clientID == clientID ? sessionID : nil
        }

        for sessionID in pendingClaudeSessionIDs {
            pendingClaudeInteractions[sessionID]?.timeoutItem.cancel()
            pendingClaudeInteractions.removeValue(forKey: sessionID)
        }

        client.readSource.cancel()
    }
}
