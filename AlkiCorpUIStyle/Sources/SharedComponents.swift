import SwiftUI

// MARK: - Button Styles

/// The primary action button style for Alki Corp UI.
public struct AlkiActionButtonStyle: ButtonStyle {
    public let accent: Color
    public let isDarkMode: Bool
    
    public init(accent: Color, isDarkMode: Bool) {
        self.accent = accent
        self.isDarkMode = isDarkMode
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                if #available(macOS 26.0, *) {
                    Capsule(style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.tint(accent.opacity(isDarkMode ? 0.34 : 0.24)).interactive(), in: .rect(cornerRadius: 999))
                } else {
                    Capsule(style: .continuous)
                        .fill(accent.opacity(isDarkMode ? 0.18 : 0.12))
                }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(accent.opacity(0.34), lineWidth: 1)
            }
            .foregroundStyle(isDarkMode ? .white : .black.opacity(0.82))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// The secondary action button style for Alki Corp UI.
public struct AlkiSecondaryButtonStyle: ButtonStyle {
    public let isDarkMode: Bool
    
    public init(isDarkMode: Bool) {
        self.isDarkMode = isDarkMode
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                if #available(macOS 26.0, *) {
                    Capsule(style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.tint(Color.white.opacity(isDarkMode ? 0.10 : 0.18)).interactive(), in: .rect(cornerRadius: 999))
                } else {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(isDarkMode ? 0.06 : 0.38))
                }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        isDarkMode ? .white.opacity(0.10) : .black.opacity(0.08),
                        lineWidth: 1
                    )
            }
            .foregroundStyle(isDarkMode ? .white.opacity(0.84) : .black.opacity(0.80))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

// MARK: - Components

/// A metric display cell with title, value, and detail.
public struct AlkiMetricCell: View {
    public let title: String
    public let value: String
    public let detail: String
    public let accent: Color
    public let isDarkMode: Bool
    
    public init(title: String, value: String, detail: String, accent: Color, isDarkMode: Bool) {
        self.title = title
        self.value = value
        self.detail = detail
        self.accent = accent
        self.isDarkMode = isDarkMode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(secondaryText)

            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            Text(detail)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(isDarkMode ? 0.04 : 0.30))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(accent.opacity(0.18), lineWidth: 1)
        }
    }

    private var secondaryText: Color {
        isDarkMode ? .white.opacity(0.55) : .black.opacity(0.58)
    }
}

/// A stylized tag pill.
public struct AlkiTagPill: View {
    public let title: String
    public let accent: Color
    public let isDarkMode: Bool
    
    public init(title: String, accent: Color, isDarkMode: Bool) {
        self.title = title
        self.accent = accent
        self.isDarkMode = isDarkMode
    }

    public var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(isDarkMode ? .white.opacity(0.86) : .black.opacity(0.78))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(isDarkMode ? 0.16 : 0.12))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(accent.opacity(0.26), lineWidth: 1)
            }
    }
}

/// A compact icon container with a glass background.
public struct AlkiCompactIcon: View {
    public let systemImage: String
    public let isDarkMode: Bool
    
    public init(systemImage: String, isDarkMode: Bool) {
        self.systemImage = systemImage
        self.isDarkMode = isDarkMode
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isDarkMode ? .black.opacity(0.26) : .white.opacity(0.55))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isDarkMode ? .white.opacity(0.07) : .black.opacity(0.08), lineWidth: 1)
            }
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
    }
}
