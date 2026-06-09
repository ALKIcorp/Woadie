import SwiftUI
import AppKit

enum WoadieTheme {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color.primary.opacity(0.035)
    static let surfaceGlass = Color.white.opacity(0.10)
    static let foreground = Color.primary
    static let foregroundMuted = Color.secondary
    static let foregroundSubtle = Color.secondary.opacity(0.72)

    static let primary = Color.primary
    static let primaryForeground = Color(nsColor: .windowBackgroundColor)
    static let success = Color(red: 0.19, green: 0.65, blue: 0.34)
    static let warning = Color(red: 0.88, green: 0.56, blue: 0.12)
    static let destructive = Color(red: 0.83, green: 0.20, blue: 0.22)

    static let border = Color.primary.opacity(0.10)
    static let borderSubtle = Color.primary.opacity(0.08)
    static let radiusSmall: CGFloat = 18
    static let radiusMedium: CGFloat = 22
    static let radiusLarge: CGFloat = 28
    static let spacing: CGFloat = 8

    static func mono(size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func rounded(size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static let noiseImage: NSImage = {
        let size = NSSize(width: 140, height: 140)
        let image = NSImage(size: size)
        image.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        for _ in 0..<900 {
            let x = CGFloat.random(in: 0..<size.width)
            let y = CGFloat.random(in: 0..<size.height)
            let alpha = CGFloat.random(in: 0.02...0.08)
            context.setFillColor(NSColor(white: 1.0, alpha: alpha).cgColor)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }()
}

@available(macOS 26.0, *)
enum GlassActivityPolicy {
    static let materialAppearance: MaterialActiveAppearance = .active
}

struct AlkiGlassSurface<Content: View>: View {
    let cornerRadius: CGFloat
    let interactive: Bool
    @ViewBuilder let content: Content

    init(
        cornerRadius: CGFloat = WoadieTheme.radiusLarge,
        interactive: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.interactive = interactive
        self.content = content()
    }

    var body: some View {
        content
            .background {
                Group {
                    if #available(macOS 26.0, *) {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.clear)
                            .glassEffect(
                                interactive
                                    ? .regular.tint(.white.opacity(0.10)).interactive()
                                    : .regular.tint(.white.opacity(0.10)),
                                in: .rect(cornerRadius: cornerRadius)
                            )
                            .materialActiveAppearance(GlassActivityPolicy.materialAppearance)
                    } else {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(WoadieTheme.borderSubtle, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
    }
}
