import SwiftUI

struct WoadieButton: View {
    enum Variant {
        case `default`
        case primary
        case ghost
    }

    let title: String
    let systemImage: String?
    let variant: Variant
    let action: () -> Void

    init(title: String, systemImage: String? = nil, variant: Variant, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.variant = variant
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .font(WoadieTheme.rounded(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(border, lineWidth: 1)
            )
            .clipShape(Capsule())
            .shadow(color: variant == .primary ? .black.opacity(0.16) : .clear, radius: 8, y: 4)
        }
        .buttonStyle(WoadiePressStyle())
    }

    private var background: Color {
        switch variant {
        case .default:
            return Color.white.opacity(0.12)
        case .primary:
            return Color.primary
        case .ghost:
            return Color.clear
        }
    }

    private var foreground: Color {
        switch variant {
        case .default:
            return WoadieTheme.foreground
        case .primary:
            return Color(nsColor: .windowBackgroundColor)
        case .ghost:
            return WoadieTheme.foregroundMuted
        }
    }

    private var border: Color {
        switch variant {
        case .default:
            return WoadieTheme.border
        case .primary:
            return Color.primary.opacity(0.18)
        case .ghost:
            return Color.clear
        }
    }
}

struct WoadiePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}
