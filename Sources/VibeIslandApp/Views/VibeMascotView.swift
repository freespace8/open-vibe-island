import SwiftUI

private enum VibeMascotPalette {
    static let body = Color(red: 0.88, green: 0.52, blue: 0.41)
    static let highlight = Color(red: 0.97, green: 0.78, blue: 0.66)
    static let ink = Color(red: 0.08, green: 0.07, blue: 0.08)
    static let shellTop = Color(red: 0.98, green: 0.98, blue: 0.99)
    static let shellBottom = Color(red: 0.86, green: 0.86, blue: 0.88)
    static let shellShadow = Color.black.opacity(0.18)
    static let warmGlow = Color(red: 0.97, green: 0.68, blue: 0.56)
    static let warmGlowEdge = Color(red: 0.79, green: 0.40, blue: 0.30)
}

private enum VibeMascotSprite {
    static let compact = [
        "..BBBB..",
        ".BBBBBB.",
        ".BBEEBB.",
        ".BBBBBB.",
        "..BBBB..",
        ".B.B.B..",
        ".B.B.B..",
    ]

    static let full = [
        "............",
        "...BBBBBB...",
        "..BBBBBBBB..",
        ".BBPPPPPPBB.",
        ".BPPBEEBPPB.",
        ".BPPPPPPPPB.",
        ".BBPPPPPPBB.",
        "..BBBBBBBB..",
        "..B.B..B.B..",
        "..B.B..B.B..",
        "............",
    ]
}

struct VibeMascotMark: View {
    let size: CGFloat
    var isAnimating: Bool = false

    var body: some View {
        PixelSprite(
            rows: size <= 18 ? VibeMascotSprite.compact : VibeMascotSprite.full,
            palette: [
                "B": VibeMascotPalette.body,
                "P": VibeMascotPalette.highlight,
                "E": VibeMascotPalette.ink,
            ]
        )
        .frame(width: size, height: size)
        .brightness(isAnimating ? 0.04 : 0)
        .shadow(
            color: isAnimating ? VibeMascotPalette.warmGlow.opacity(0.35) : .clear,
            radius: size * 0.2,
            y: size * 0.06
        )
        .scaleEffect(isAnimating ? 1.04 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isAnimating)
    }
}

struct VibeMascotBadge: View {
    let size: CGFloat
    var isAnimating: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            VibeMascotPalette.shellTop,
                            Color.white,
                            VibeMascotPalette.shellBottom,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.78), lineWidth: max(1, size * 0.016))
                .padding(size * 0.016)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            VibeMascotPalette.warmGlow.opacity(0.9),
                            VibeMascotPalette.warmGlowEdge.opacity(0.22),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.28
                    )
                )
                .frame(width: size * 0.72, height: size * 0.72)
                .offset(x: size * 0.18, y: size * 0.2)
                .blur(radius: size * 0.035)

            PixelDitherField(color: VibeMascotPalette.ink.opacity(0.22))
                .frame(height: size * 0.45)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .mask(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .padding(.horizontal, size * 0.08)
                .padding(.bottom, size * 0.08)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.18, blue: 0.19),
                            Color.black,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size * 0.76, height: size * 0.36)
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(width: size * 0.54, height: size * 0.028)
                        .offset(y: size * 0.024)
                }
                .overlay {
                    VibeMascotMark(size: size * 0.28, isAnimating: isAnimating)
                }
                .offset(y: -size * 0.16)
        }
        .frame(width: size, height: size)
        .shadow(color: VibeMascotPalette.shellShadow, radius: size * 0.12, y: size * 0.05)
    }
}

private struct PixelSprite: View {
    let rows: [String]
    let palette: [Character: Color]

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let rowCount = rows.count
                let columnCount = rows.map(\.count).max() ?? 1
                let pixelSize = min(size.width / CGFloat(columnCount), size.height / CGFloat(rowCount))
                let spriteWidth = CGFloat(columnCount) * pixelSize
                let spriteHeight = CGFloat(rowCount) * pixelSize
                let originX = (size.width - spriteWidth) / 2
                let originY = (size.height - spriteHeight) / 2
                let pixelInset = max(0, pixelSize * 0.08)

                for (rowIndex, row) in rows.enumerated() {
                    for (columnIndex, symbol) in row.enumerated() {
                        guard let color = palette[symbol] else {
                            continue
                        }

                        let pixelRect = CGRect(
                            x: originX + CGFloat(columnIndex) * pixelSize + pixelInset,
                            y: originY + CGFloat(rowIndex) * pixelSize + pixelInset,
                            width: max(1, pixelSize - (pixelInset * 2)),
                            height: max(1, pixelSize - (pixelInset * 2))
                        )

                        let pixelPath = Path(CGPath(rect: pixelRect, transform: nil))
                        context.fill(pixelPath, with: .color(color))
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .drawingGroup(opaque: false)
    }
}

private struct PixelDitherField: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let spacing = max(5, floor(min(size.width, size.height) / 14))
                let dotSize = max(1.4, spacing * 0.24)
                let hotspot = CGPoint(x: size.width * 0.78, y: size.height * 0.54)
                let maxDistance = max(size.width, size.height) * 0.92

                var rowIndex = 0
                var y: CGFloat = 0
                while y <= size.height {
                    var x: CGFloat = rowIndex.isMultiple(of: 2) ? 0 : spacing / 2
                    while x <= size.width {
                        let distance = hypot(x - hotspot.x, y - hotspot.y)
                        let alpha = max(0.04, 0.34 - (distance / maxDistance) * 0.28)
                        let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
                        x += spacing
                    }

                    rowIndex += 1
                    y += spacing
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
