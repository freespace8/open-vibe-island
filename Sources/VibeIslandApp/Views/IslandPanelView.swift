import SwiftUI
import VibeIslandCore

// MARK: - Animations

private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
private let popAnimation = Animation.spring(response: 0.3, dampingFraction: 0.5)

// MARK: - Main island view

struct IslandPanelView: View {
    var model: AppModel

    @Namespace private var notchNamespace
    @State private var isHovering = false

    private var isOpened: Bool {
        model.notchStatus == .opened
    }

    private var isPopping: Bool {
        model.notchStatus == .popping
    }

    private var closedSpotlightSession: AgentSession? {
        model.surfacedSessions.first(where: { $0.phase.requiresAttention })
            ?? model.surfacedSessions.first(where: { $0.phase == .running })
            ?? model.surfacedSessions.first
    }

    private var hasClosedPresence: Bool {
        model.liveSessionCount > 0
    }

    /// Whether any session has activity worth showing in the closed notch
    private var hasClosedActivity: Bool {
        guard let session = closedSpotlightSession else {
            return false
        }
        return session.phase == .running || session.phase.requiresAttention
    }

    private var countBadgeWidth: CGFloat {
        let digits = max(1, "\(model.liveSessionCount)".count)
        return CGFloat(18 + max(0, digits - 1) * 7)
    }

    private var expansionWidth: CGFloat {
        guard hasClosedPresence else { return 0 }
        let leftWidth = sideWidth + 8 + (closedSpotlightSession?.phase.requiresAttention == true ? 18 : 0)
        let rightWidth = max(sideWidth, countBadgeWidth)
        let hasPending = closedSpotlightSession?.phase.requiresAttention == true
        return leftWidth + rightWidth + 16 + (hasPending ? 6 : 0)
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchHeight - 12) + 10
    }

    private var openedPanelHeight: CGFloat {
        500
    }

    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width

            ZStack(alignment: .top) {
                Color.clear

                notchContent(screenWidth: screenWidth)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func notchContent(screenWidth: CGFloat) -> some View {
        let openedWidth = min(max(screenWidth * 0.68, 760), screenWidth - 36)
        let closedWidth = closedNotchWidth + expansionWidth + (isPopping ? 18 : 0)
        let currentWidth = isOpened ? openedWidth : closedWidth
        let currentHeight = isOpened ? openedPanelHeight : closedNotchHeight

        VStack(spacing: 0) {
            headerRow
                .frame(height: closedNotchHeight)

            if isOpened {
                openedContent
                    .frame(width: openedWidth - 24)
                    .frame(maxHeight: openedPanelHeight - closedNotchHeight - 12, alignment: .top)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
        .frame(width: currentWidth, height: currentHeight, alignment: .top)
        .padding(.horizontal, isOpened ? 14 : 0)
        .padding(.bottom, isOpened ? 14 : 0)
        .background(surfaceFill)
        .clipShape(
            NotchShape(
                topCornerRadius: isOpened ? NotchShape.openedTopRadius : NotchShape.closedTopRadius,
                bottomCornerRadius: isOpened ? NotchShape.openedBottomRadius : NotchShape.closedBottomRadius
            )
        )
        .overlay(alignment: .top) {
            // Black strip to blend with physical notch at the very top
            Rectangle()
                .fill(Color.black)
                .frame(height: 1)
                .padding(.horizontal, isOpened ? NotchShape.openedTopRadius : NotchShape.closedTopRadius)
        }
        .overlay {
            NotchShape(
                topCornerRadius: isOpened ? NotchShape.openedTopRadius : NotchShape.closedTopRadius,
                bottomCornerRadius: isOpened ? NotchShape.openedBottomRadius : NotchShape.closedBottomRadius
            )
            .stroke(Color.white.opacity(isOpened ? 0.07 : 0.04), lineWidth: 1)
        }
        .shadow(
            color: (isOpened || isHovering) ? .black.opacity(0.46) : .clear,
            radius: 16,
            y: 8
        )
        .animation(isOpened ? openAnimation : closeAnimation, value: model.notchStatus)
        .animation(.smooth, value: hasClosedPresence)
        .animation(.smooth, value: expansionWidth)
        .animation(popAnimation, value: isPopping)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            if !isOpened {
                model.notchOpen(reason: .click)
            }
        }
    }

    // MARK: - Closed state

    private var closedNotchWidth: CGFloat {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })?.notchSize.width ?? 224
    }

    private var closedNotchHeight: CGFloat {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })?.notchSize.height ?? 38
    }

    // MARK: - Header row (shared between closed and opened)

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            if hasClosedPresence || isOpened {
                HStack(spacing: 4) {
                    VibeIslandIcon(size: 14, isAnimating: hasClosedActivity)
                        .matchedGeometryEffect(id: "island-icon", in: notchNamespace, isSource: hasClosedPresence || isOpened)

                    if closedSpotlightSession?.phase.requiresAttention == true {
                        AttentionIndicator(
                            size: 14,
                            color: phaseColor(closedSpotlightSession?.phase ?? .running)
                        )
                    }
                }
                .frame(width: isOpened ? nil : sideWidth + 8 + (closedSpotlightSession?.phase.requiresAttention == true ? 18 : 0))
                .padding(.leading, isOpened ? 8 : 0)
            }

            if isOpened {
                openedHeaderContent
            } else if !hasClosedPresence {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: closedNotchWidth - 20)
            } else {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: closedNotchWidth - NotchShape.closedTopRadius + (isPopping ? 18 : 0))
            }

            if isOpened {
                EmptyView()
            } else if hasClosedPresence {
                ClosedCountBadge(
                    liveCount: model.liveSessionCount,
                    tint: closedSpotlightSession?.phase.requiresAttention == true ? .orange : (hasClosedActivity ? .mint : .white.opacity(0.7))
                )
                .matchedGeometryEffect(id: "right-indicator", in: notchNamespace, isSource: hasClosedPresence)
                .frame(width: max(sideWidth, countBadgeWidth))
            }
        }
        .frame(height: closedNotchHeight)
    }

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 12) {
            if !hasClosedPresence {
                VibeIslandIcon(size: 14, isAnimating: false)
                    .matchedGeometryEffect(id: "island-icon", in: notchNamespace, isSource: !hasClosedPresence)
                    .padding(.leading, 8)
            }

            openedUsageSummary
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                headerPill("\(model.state.runningCount) live", tint: .white.opacity(0.7))

                if model.state.attentionCount > 0 {
                    headerPill("\(model.state.attentionCount) attention", tint: .orange.opacity(0.95))
                }

                Button {
                    model.notchClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 20, height: 20)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    private var openedContent: some View {
        VStack(spacing: 0) {
            if model.surfacedSessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("No active sessions")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Text("Start Codex in your terminal")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.25))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(displayedSessions) { session in
                    IslandSessionRow(
                        session: session,
                        isSelected: session.id == model.focusedSession?.id,
                        onSelect: { model.select(sessionID: session.id) },
                        onJump: { model.jumpToSession(session) },
                        onApprove: { model.approvePermission(for: session.id, approved: $0) },
                        onAnswer: { model.answerQuestion(for: session.id, answer: $0) }
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private var displayedSessions: [AgentSession] {
        model.surfacedSessions + model.recentSessions
    }

    // MARK: - Helpers

    private var surfaceFill: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 0.12, green: 0.12, blue: 0.13),
                Color(red: 0.03, green: 0.03, blue: 0.04),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func phaseColor(_ phase: SessionPhase) -> Color {
        switch phase {
        case .running: .mint
        case .waitingForApproval: .orange
        case .waitingForAnswer: .yellow
        case .completed: .blue
        }
    }

    @ViewBuilder
    private var openedUsageSummary: some View {
        if let snapshot = model.claudeUsageSnapshot,
           snapshot.isEmpty == false {
            HStack(spacing: 8) {
                Text("Claude")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                if let fiveHour = snapshot.fiveHour {
                    usageWindowView(label: "5h", window: fiveHour)
                }

                if let fiveHour = snapshot.fiveHour,
                   let sevenDay = snapshot.sevenDay,
                   fiveHour.usedPercentage >= 0,
                   sevenDay.usedPercentage >= 0 {
                    Text("|")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.16))
                }

                if let sevenDay = snapshot.sevenDay {
                    usageWindowView(label: "7d", window: sevenDay)
                }
            }
            .lineLimit(1)
        } else {
            HStack(spacing: 8) {
                Text("Vibe Island")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Claude usage waiting")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .lineLimit(1)
        }
    }

    private func usageWindowView(label: String, window: ClaudeUsageWindow) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))

            Text("\(window.roundedUsedPercentage)%")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(usageColor(for: window.usedPercentage))

            if let resetsAt = window.resetsAt,
               let remaining = remainingDurationString(until: resetsAt) {
                Text(remaining)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private func headerPill(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.08), in: Capsule())
    }

    private func usageColor(for percentage: Double) -> Color {
        switch percentage {
        case 90...:
            .red.opacity(0.95)
        case 70..<90:
            .orange.opacity(0.95)
        default:
            .green.opacity(0.95)
        }
    }

    private func remainingDurationString(until date: Date) -> String? {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else {
            return nil
        }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated

        if interval >= 86_400 {
            formatter.allowedUnits = [.day]
            formatter.maximumUnitCount = 1
        } else if interval >= 3_600 {
            formatter.allowedUnits = [.hour, .minute]
            formatter.maximumUnitCount = 2
        } else {
            formatter.allowedUnits = [.minute]
            formatter.maximumUnitCount = 1
        }

        return formatter.string(from: interval)
    }
}

// MARK: - Session row (opened state)

private struct IslandSessionRow: View {
    let session: AgentSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onJump: () -> Void
    let onApprove: (Bool) -> Void
    let onAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: handlePrimaryTap) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)

                    VStack(alignment: .leading, spacing: isSelected ? 4 : 2) {
                        Text(session.spotlightHeadlineText)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let promptLine = session.spotlightPromptLineText {
                            Text(promptLine)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1)
                        }

                        if let activityLine = session.spotlightActivityLineText {
                            Text(activityLine)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(activityColor.opacity(0.94))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 6) {
                            compactBadge(session.tool.displayName)
                            if let terminalBadge = session.spotlightTerminalBadge {
                                compactBadge(terminalBadge)
                            }
                            compactBadge(session.spotlightAgeBadge)
                        }

                        if isSelected {
                            compactBadge(session.spotlightStatusLabel)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            if isSelected {
                actionRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isSelected ? 14 : 12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isSelected ? Color(red: 0.13, green: 0.13, blue: 0.14) : Color(red: 0.05, green: 0.05, blue: 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isSelected ? .white.opacity(0.08) : .white.opacity(0.025))
        )
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(isSelected ? 0 : 0.03))
                .frame(height: 1),
            alignment: .bottom
        )
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private var actionRow: some View {
        if let request = session.permissionRequest {
            HStack(spacing: 8) {
                Text(request.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button(request.secondaryActionTitle) { onApprove(false) }
                    .buttonStyle(IslandCompactButtonStyle(tint: .secondary))
                Button(request.primaryActionTitle) { onApprove(true) }
                    .buttonStyle(IslandCompactButtonStyle(tint: .orange))
            }
        } else if let prompt = session.questionPrompt {
            HStack(spacing: 8) {
                Text(prompt.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow.opacity(0.9))
                    .lineLimit(2)
                Spacer(minLength: 8)
                ForEach(prompt.options.prefix(2), id: \.self) { option in
                    Button(option) { onAnswer(option) }
                        .buttonStyle(IslandCompactButtonStyle(tint: .secondary))
                }
            }
        }
    }

    private func handlePrimaryTap() {
        if session.permissionRequest != nil || session.questionPrompt != nil {
            onSelect()
            return
        }

        if session.jumpTarget != nil {
            onJump()
        } else {
            onSelect()
        }
    }

    private func compactBadge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.56))
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(Color(red: 0.14, green: 0.14, blue: 0.15), in: Capsule())
    }

    private var statusColor: Color {
        switch session.phase {
        case .running: .mint
        case .waitingForApproval: .orange
        case .waitingForAnswer: .yellow
        case .completed: session.jumpTarget != nil ? .white.opacity(0.5) : .blue
        }
    }

    private var activityColor: Color {
        switch session.spotlightActivityTone {
        case .live:
            Color(red: 0.36, green: 0.64, blue: 1.0)
        case .idle:
            .white.opacity(0.46)
        case .ready:
            .green.opacity(0.92)
        case .attention:
            .orange.opacity(0.94)
        }
    }
}

// MARK: - Compact button style

private struct IslandCompactButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint == .secondary ? .white.opacity(0.7) : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                (tint == .secondary ? Color.white.opacity(0.08) : tint.opacity(0.15)),
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Vibe Island icon (left side of closed notch)

private struct VibeIslandIcon: View {
    let size: CGFloat
    var isAnimating: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                iconBlock
                iconBlock
            }
            HStack(spacing: 2) {
                iconBlock
                iconBlock
            }
        }
        .frame(width: size, height: size)
    }

    private var iconBlock: some View {
        RoundedRectangle(cornerRadius: 1.8, style: .continuous)
            .fill(Color.mint.opacity(isAnimating ? 1.0 : 0.82))
    }
}

// MARK: - Attention indicator (permission/question dot)

private struct AttentionIndicator: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: size * 0.75, weight: .bold))
            .foregroundStyle(color)
    }
}

// MARK: - Closed count badge (right side of closed notch)

private struct ClosedCountBadge: View {
    let liveCount: Int
    let tint: Color

    var body: some View {
        Text("\(liveCount)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(red: 0.14, green: 0.14, blue: 0.15), in: Capsule())
    }
}

// MARK: - Menu bar content (unchanged)

struct MenuBarContentView: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vibe Island OSS")
                .font(.headline)
            Text("\(model.liveSessionCount) live · \(model.liveAttentionCount) attention")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            Button("Open Control Center") {
                model.showControlCenter()
            }

            Text(model.acceptanceStatusTitle)
                .font(.subheadline.weight(.semibold))
            Text(model.acceptanceStatusSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button(model.isOverlayVisible ? "Hide Island Overlay" : "Show Island Overlay") {
                model.toggleOverlay()
            }

            Divider()

            Text(model.codexHookStatusTitle)
                .font(.subheadline.weight(.semibold))
            Text(model.codexHookStatusSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Refresh Codex Hook Status") {
                model.refreshCodexHookStatus()
            }

            if model.codexHooksInstalled {
                Button("Uninstall Codex Hooks") {
                    model.uninstallCodexHooks()
                }
            } else {
                Button("Install Codex Hooks") {
                    model.installCodexHooks()
                }
                .disabled(model.hooksBinaryURL == nil)
            }

            if let session = model.focusedSession {
                Divider()
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                Text(session.spotlightPrimaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let currentTool = session.spotlightCurrentToolLabel {
                    Text("Live tool: \(currentTool)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let trackingLabel = session.spotlightTrackingLabel {
                    Text("Tracking: \(trackingLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
