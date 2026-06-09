import AppKit
import SwiftUI

struct PersistentVisualEffectView: NSViewRepresentable {
    let cornerRadius: CGFloat

    static func makeVisualEffectView(cornerRadius: CGFloat) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view, cornerRadius: cornerRadius)
        return view
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        Self.makeVisualEffectView(cornerRadius: cornerRadius)
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        Self.configure(view, cornerRadius: cornerRadius)
    }

    private static func configure(_ view: NSVisualEffectView, cornerRadius: CGFloat) {
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}

struct WoadieGlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let fallbackOpacity: Double

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
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
