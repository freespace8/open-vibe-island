import SwiftUI

struct OpenIslandBrandMark: View {
    enum Style {
        case duotone
        case template
    }

    let size: CGFloat
    var tint: Color = .mint
    var isAnimating: Bool = false
    var style: Style = .duotone

    private static let scoutPattern = [
        "..B..B..",
        "..BBBB..",
        ".BHHHHB.",
        "BBHEHEBB",
        ".BHHHHB.",
        "..BBBB..",
        ".B....B.",
        "........",
    ]

    private static let pixels: [(x: Int, y: Int, role: Character)] = scoutPattern.enumerated().flatMap { rowIndex, row in
        row.enumerated().compactMap { columnIndex, character in
            character == "." ? nil : (columnIndex, rowIndex, character)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.14, paused: !isAnimating)) { context in
            GeometryReader { proxy in
                let cell = min(proxy.size.width / 8, proxy.size.height / 8)
                let markWidth = cell * 8
                let markHeight = cell * 8
                let originX = (proxy.size.width - markWidth) / 2
                let originY = (proxy.size.height - markHeight) / 2
                let animationPhase = pulsePhase(for: context.date)

                ZStack(alignment: .topLeading) {
                    ForEach(Array(Self.pixels.enumerated()), id: \.offset) { _, pixel in
                        Rectangle()
                            .fill(fillColor(for: pixel.role, phase: animationPhase))
                            .frame(width: cell, height: cell)
                            .offset(
                                x: originX + CGFloat(pixel.x) * cell,
                                y: originY + CGFloat(pixel.y) * cell
                            )
                    }
                }
            }
            .frame(width: size, height: size)
            .drawingGroup(opaque: false, colorMode: .extendedLinear)
        }
    }

    private func pulsePhase(for date: Date) -> Double {
        guard isAnimating else { return 0 }
        let cycle = date.timeIntervalSinceReferenceDate * 5.5
        return (sin(cycle) + 1) / 2
    }

    private func fillColor(for role: Character, phase: Double) -> Color {
        switch style {
        case .duotone:
            switch role {
            case "B":
                return tint.opacity(isAnimating ? (0.78 + (phase * 0.22)) : 0.86)
            case "H":
                return tint.opacity(isAnimating ? (0.54 + (phase * 0.3)) : 0.64)
            case "E":
                return Color.black.opacity(0.72)
            default:
                return .clear
            }
        case .template:
            return Color.primary.opacity(role == "E" ? 0.9 : 1.0)
        }
    }
}
