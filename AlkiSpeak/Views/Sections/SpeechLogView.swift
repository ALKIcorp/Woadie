import SwiftUI

struct SpeechLogView: View {
    let entries: [AppModel.ChatItem]
    let playingId: UUID?
    let onReplay: (AppModel.ChatItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History")
                    .font(WoadieTheme.mono(size: 11, weight: .medium))
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
                    .textCase(.uppercase)
                    .tracking(1.4)
                Spacer()
                Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries")")
                    .font(WoadieTheme.mono(size: 10, weight: .medium))
                    .foregroundStyle(WoadieTheme.foregroundSubtle.opacity(0.6))
            }

            if entries.isEmpty {
                VStack(spacing: 4) {
                    Text("No history yet")
                        .font(WoadieTheme.mono(size: 11, weight: .medium))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                        .textCase(.uppercase)
                        .tracking(1.2)
                    Text("Speak something to see it here")
                        .font(WoadieTheme.mono(size: 11, weight: .regular))
                        .foregroundStyle(WoadieTheme.foregroundSubtle.opacity(0.6))
                }
                .frame(maxWidth: .infinity, minHeight: 200)
                .background(WoadieTheme.surface.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(WoadieTheme.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [6]))
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(entries) { entry in
                                SpeechLogItemView(
                                    entry: entry,
                                    isPlaying: playingId == entry.id,
                                    onReplay: { onReplay(entry) }
                                )
                            }
                        }
                        .padding(.bottom, 16)
                    }
                    .frame(maxHeight: 360)

                    if entries.count > 3 {
                        LinearGradient(
                            colors: [
                                WoadieTheme.background.opacity(0),
                                WoadieTheme.background
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 40)
                    }
                }
            }
        }
    }
}
