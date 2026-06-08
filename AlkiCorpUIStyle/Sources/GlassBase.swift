import SwiftUI

/// A reusable glass card container that adapts to macOS versions.
public struct GlassCard<Content: View>: View {
    public let cornerRadius: CGFloat
    public let tint: Color
    public let interactive: Bool
    @ViewBuilder public var content: Content

    public init(cornerRadius: CGFloat = 20, tint: Color = .white.opacity(0.1), interactive: Bool = false, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.interactive = interactive
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, *) {
            // Future-proof glass effect implementation
            GlassEffectContainer(spacing: 24) {
                content
                    .padding(0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassEffect(
                        interactive ? .regular.tint(tint).interactive() : .regular.tint(tint),
                        in: .rect(cornerRadius: cornerRadius)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    }
            }
        } else {
            // Fallback for current macOS versions
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                }
        }
    }
}

/// A specialized glass menu container.
public struct GlassMenu<Content: View>: View {
    public let width: CGFloat
    public let accent: Color
    @ViewBuilder public var content: Content

    public init(width: CGFloat, accent: Color, @ViewBuilder content: () -> Content) {
        self.width = width
        self.accent = accent
        self.content = content()
    }

    public var body: some View {
        GlassCard(cornerRadius: 20, tint: accent, interactive: false) {
            content
                .padding(8)
                .frame(width: width)
        }
        .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
    }
}

/// A view that wraps a component with a glass background and stroke.
public struct GlassSurface<Content: View>: View {
    public let accent: Color
    public let isDarkMode: Bool
    public let cornerRadius: CGFloat
    @ViewBuilder public var content: Content

    public init(accent: Color, isDarkMode: Bool, cornerRadius: CGFloat = 28, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.isDarkMode = isDarkMode
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 24) {
                content
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .glassEffect(.regular.tint(accent), in: .rect(cornerRadius: cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                isDarkMode ? .white.opacity(0.10) : .black.opacity(0.08),
                                lineWidth: 1
                            )
                    }
            }
        } else {
            content
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(accent.opacity(0.05)) // Subtle tint fallback
                        }
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            isDarkMode ? .white.opacity(0.08) : .black.opacity(0.08),
                            lineWidth: 1
                        )
                }
        }
    }
}
