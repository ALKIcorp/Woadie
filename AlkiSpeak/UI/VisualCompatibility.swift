import SwiftUI

struct WoadieGlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let fallbackOpacity: Double

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .materialActiveAppearance(GlassActivityPolicy.materialAppearance)
        } else {
            content
                .background(WoadieTheme.surface.opacity(fallbackOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(WoadieTheme.borderSubtle, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    func woadieGlassPanel(cornerRadius: CGFloat = 14, fallbackOpacity: Double = 0.6) -> some View {
        modifier(WoadieGlassPanelModifier(cornerRadius: cornerRadius, fallbackOpacity: fallbackOpacity))
    }
}
