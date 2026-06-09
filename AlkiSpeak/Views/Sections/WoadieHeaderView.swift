import AppKit
import SwiftUI

struct WoadieHeaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            WindowTrafficLightControls()
            Spacer()
            Text("AlkiSpeak")
                .font(WoadieTheme.rounded(size: 13, weight: .semibold))
                .tracking(0.2)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 2)
    }
}

private struct WindowTrafficLightControls: View {
    @State private var closeHover = false
    @State private var minimizeHover = false
    @State private var zoomHover = false

    var body: some View {
        HStack(spacing: 8) {
            WindowControlDot(color: .red, isHovered: closeHover) {
                NSApp.keyWindow?.performClose(nil)
            }
            .onHover { closeHover = $0 }

            WindowControlDot(color: .yellow, isHovered: minimizeHover) {
                NSApp.keyWindow?.miniaturize(nil)
            }
            .onHover { minimizeHover = $0 }

            WindowControlDot(color: .green, isHovered: zoomHover) {
                NSApp.keyWindow?.performZoom(nil)
            }
            .onHover { zoomHover = $0 }
        }
        .frame(width: 92, alignment: .leading)
    }
}

private struct WindowControlDot: View {
    let color: Color
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.opacity(isHovered ? 1.0 : 0.85))
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .strokeBorder(Color.black.opacity(isHovered ? 0.22 : 0.10), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}
