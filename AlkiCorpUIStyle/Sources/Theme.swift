import SwiftUI

/// The core color system for Alki Corp UI.
public struct ThemePalette: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let hex: String
    public let darkBase: Color
    public let lightBase: Color

    public var accent: Color { Color(hex: hex) }
    
    public init(id: String, name: String, hex: String, darkBase: Color, lightBase: Color) {
        self.id = id
        self.name = name
        self.hex = hex
        self.darkBase = darkBase
        self.lightBase = lightBase
    }
}

/// The standard Alki Corp theme collection.
public let AlkiThemes: [ThemePalette] = [
    .init(id: "onyx", name: "Onyx Base", hex: "#6366f1", darkBase: Color(hex: "#000000"), lightBase: Color(hex: "#f4f4f5")),
    .init(id: "chrome", name: "Chrome Heart", hex: "#ffffff", darkBase: Color(hex: "#000000"), lightBase: Color(hex: "#e4e4e7")),
    .init(id: "y3", name: "Y3 Signal", hex: "#ef4444", darkBase: Color(hex: "#0a0a0a"), lightBase: Color(hex: "#fef2f2")),
    .init(id: "ghost", name: "Neon Ghost", hex: "#06b6d4", darkBase: Color(hex: "#020617"), lightBase: Color(hex: "#ecfeff")),
    .init(id: "sakura", name: "Sakura Drift", hex: "#f472b6", darkBase: Color(hex: "#500724"), lightBase: Color(hex: "#fdf2f8")),
    .init(id: "velvet", name: "Midnight Velvet", hex: "#a855f7", darkBase: Color(hex: "#3b0764"), lightBase: Color(hex: "#faf5ff")),
    .init(id: "acid", name: "Acid Rain", hex: "#84cc16", darkBase: Color(hex: "#1c1917"), lightBase: Color(hex: "#f7fee7")),
    .init(id: "desert", name: "Desert Tech", hex: "#d97706", darkBase: Color(hex: "#431407"), lightBase: Color(hex: "#fffbeb")),
    .init(id: "glacier", name: "Glacier", hex: "#38bdf8", darkBase: Color(hex: "#082f49"), lightBase: Color(hex: "#f0f9ff")),
    .init(id: "blood", name: "Blood Moon", hex: "#be123c", darkBase: Color(hex: "#4c0519"), lightBase: Color(hex: "#fff1f2"))
]

/// Ambient background view used in The Grid.
public struct AlkiBackgroundView: View {
    public let displayTheme: ThemePalette
    public let isDarkMode: Bool
    
    public init(displayTheme: ThemePalette, isDarkMode: Bool) {
        self.displayTheme = displayTheme
        self.isDarkMode = isDarkMode
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let largestSide = max(size.width, size.height)

            ZStack {
                (isDarkMode ? displayTheme.darkBase : displayTheme.lightBase)
                    .ignoresSafeArea()

                // Ambient glow clusters
                Circle()
                    .fill(displayTheme.accent.opacity(isDarkMode ? 0.22 : 0.14))
                    .frame(width: largestSide * 1.15, height: largestSide * 1.15)
                    .blur(radius: largestSide * 0.12)
                    .offset(x: -largestSide * 0.30, y: -largestSide * 0.34)

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                displayTheme.accent.opacity(isDarkMode ? 0.18 : 0.12),
                                displayTheme.accent.opacity(isDarkMode ? 0.08 : 0.04),
                                .clear
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: largestSide * 0.56
                        )
                    )
                    .frame(width: size.width * 0.92, height: largestSide * 0.78)
                    .position(x: size.width * 0.52, y: size.height * 0.04)

                Circle()
                    .fill(displayTheme.accent.opacity(isDarkMode ? 0.16 : 0.11))
                    .frame(width: largestSide * 0.94, height: largestSide * 0.94)
                    .blur(radius: largestSide * 0.16)
                    .position(x: size.width * 0.95, y: size.height * 0.16)

                Canvas { context, canvasSize in
                    let rect = CGRect(origin: .zero, size: canvasSize)
                    context.fill(
                        Path(rect),
                        with: .linearGradient(
                            Gradient(colors: [
                                Color.white.opacity(isDarkMode ? 0.03 : 0.12),
                                .clear,
                                displayTheme.accent.opacity(isDarkMode ? 0.05 : 0.03)
                            ]),
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: canvasSize.width, y: canvasSize.height)
                        )
                    )
                }
                .blendMode(.plusLighter)
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
    }
}

extension Color {
    public init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch sanitized.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 255, 255, 255)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
