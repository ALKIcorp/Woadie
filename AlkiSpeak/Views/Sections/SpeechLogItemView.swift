import SwiftUI
import AppKit

struct SpeechLogItemView: View {
    let entry: AppModel.ChatItem
    let isPlaying: Bool
    let onReplay: () -> Void
    @State private var isHovered = false
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .leading) {
            if isPlaying {
                Rectangle()
                    .fill(WoadieTheme.primary)
                    .frame(width: 2)
                    .cornerRadius(1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(entry.text)
                    .font(WoadieTheme.mono(size: 13, weight: .regular))
                    .foregroundStyle(WoadieTheme.foreground)
                    .lineSpacing(3)
                    .padding(.trailing, 60)

                Text(WoadieTheme.timeFormatter.string(from: entry.timestamp))
                    .font(WoadieTheme.mono(size: 10, weight: .medium))
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
                    .textCase(.uppercase)
                    .tracking(1.2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(isPlaying ? WoadieTheme.primary.opacity(0.08) : WoadieTheme.surface.opacity(0.7))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isPlaying ? WoadieTheme.primary.opacity(0.5) : WoadieTheme.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                IconActionButton(systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copyToClipboard()
                }
                IconActionButton(systemImage: "speaker.wave.2.fill") {
                    onReplay()
                }
            }
            .opacity(isHovered ? 1 : 0)
            .padding(10)
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}
