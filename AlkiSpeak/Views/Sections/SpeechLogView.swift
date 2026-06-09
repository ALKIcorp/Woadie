import SwiftUI

struct SpeechLogView: View {
    let entries: [SpeechEntry]
    let playingId: UUID?
    let selectedId: UUID?
    let logMode: LogMode
    let onLogModeChanged: (LogMode) -> Void
    let onSelect: (SpeechEntry) -> Void
    let onOpen: (SpeechEntry) -> Void
    let onDelete: (SpeechEntry) -> Void

    var body: some View {
        AlkiGlassSurface {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Log Console")
                    .font(WoadieTheme.mono(size: 11, weight: .medium))
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
                    .textCase(.uppercase)
                    .tracking(1.4)
                Spacer()
                Picker("Log Mode", selection: Binding(
                    get: { logMode },
                    set: { onLogModeChanged($0) }
                )) {
                    Text("Auto").tag(LogMode.auto)
                    Text("Manual").tag(LogMode.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Log Mode")
                .frame(width: 150)
                .help(logMode == .auto ? "Every speech is automatically added to the log" : "Manually choose which speeches to save to the log")

                Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries")")
                    .font(WoadieTheme.mono(size: 10, weight: .medium))
                    .foregroundStyle(WoadieTheme.foregroundSubtle.opacity(0.6))
            }

            if entries.isEmpty {
                VStack(spacing: 4) {
                    Text("No log entries yet")
                        .font(WoadieTheme.mono(size: 11, weight: .medium))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                        .textCase(.uppercase)
                        .tracking(1.2)
                    Text(logMode == .auto ? "Every Pro speech appears here" : "Use Add to Log after generating speech")
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
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            ForEach(entries) { entry in
                                SpeechLogItemView(
                                    entry: entry,
                                    isPlaying: playingId == entry.id,
                                    isSelected: selectedId == entry.id,
                                    onSelect: { onSelect(entry) },
                                    onOpen: { onOpen(entry) },
                                    onDelete: { onDelete(entry) }
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
        .padding(18)
        }
    }
}
