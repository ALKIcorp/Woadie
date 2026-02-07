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
            .padding(.vertical, 7)
            .font(WoadieTheme.mono(size: 12, weight: .medium))
            .textCase(.uppercase)
            .tracking(1)
            .frame(height: 34)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: variant == .primary ? WoadieTheme.primary.opacity(0.35) : .clear, radius: 12, x: 0, y: 0)
        }
        .buttonStyle(WoadiePressStyle())
    }

    private var background: Color {
        switch variant {
        case .default:
            return WoadieTheme.surface
        case .primary:
            return WoadieTheme.primary
        case .ghost:
            return Color.clear
        }
    }

    private var foreground: Color {
        switch variant {
        case .default:
            return WoadieTheme.foregroundMuted
        case .primary:
            return WoadieTheme.primaryForeground
        case .ghost:
            return WoadieTheme.foregroundMuted
        }
    }

    private var border: Color {
        switch variant {
        case .default:
            return WoadieTheme.border
        case .primary:
            return WoadieTheme.primary.opacity(0.7)
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
