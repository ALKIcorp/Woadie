import SwiftUI

private struct LogScrollMetrics: Equatable {
    var offsetX: CGFloat = 0
    var contentWidth: CGFloat = 0
    var containerWidth: CGFloat = 0
}

private struct ScrollGeometryTrackingModifier: ViewModifier {
    @Binding var scrollMetrics: LogScrollMetrics

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: LogScrollMetrics.self) { geometry in
                LogScrollMetrics(
                    offsetX: geometry.contentOffset.x,
                    contentWidth: geometry.contentSize.width,
                    containerWidth: geometry.containerSize.width
                )
            } action: { _, newValue in
                scrollMetrics = newValue
            }
        } else {
            content
        }
    }
}

struct SpeechLogView: View {
    let entries: [SpeechEntry]
    let playingId: UUID?
    let selectedId: UUID?
    let logMode: LogMode
    let onLogModeChanged: (LogMode) -> Void
    let onSelect: (SpeechEntry) -> Void
    let onOpen: (SpeechEntry) -> Void
    let onReinsert: (SpeechEntry) -> Void
    let onDelete: (SpeechEntry) -> Void

    @State private var scrollMetrics = LogScrollMetrics()

    private var canScroll: Bool {
        scrollMetrics.contentWidth > scrollMetrics.containerWidth + 1
    }

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
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(WoadieTheme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(WoadieTheme.borderSubtle))
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
                VStack(spacing: 8) {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            ForEach(entries) { entry in
                                SpeechLogItemView(
                                    entry: entry,
                                    isPlaying: playingId == entry.id,
                                    isSelected: selectedId == entry.id,
                                    onSelect: { onSelect(entry) },
                                    onOpen: { onOpen(entry) },
                                    onReinsert: { onReinsert(entry) },
                                    onDelete: { onDelete(entry) }
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                    .modifier(ScrollGeometryTrackingModifier(scrollMetrics: $scrollMetrics))
                    .frame(maxHeight: 360)
                    .mask(
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [.black.opacity(0), .black],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: canScroll ? 18 : 0)
                            Rectangle().fill(.black)
                            LinearGradient(
                                colors: [.black, .black.opacity(0)],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: canScroll ? 18 : 0)
                        }
                    )

                    if canScroll {
                        LogScrollScrubber(metrics: scrollMetrics)
                    }
                }
            }
        }
        .padding(18)
        }
    }
}

/// Thin capsule scrubber that mirrors the horizontal scroll position of the log carousel.
private struct LogScrollScrubber: View {
    let metrics: LogScrollMetrics

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = proxy.size.width
            let maxOffset = max(metrics.contentWidth - metrics.containerWidth, 1)
            let progress = min(max(metrics.offsetX / maxOffset, 0), 1)
            let thumbRatio = metrics.contentWidth > 0
                ? min(max(metrics.containerWidth / metrics.contentWidth, 0.12), 1)
                : 1
            let thumbWidth = trackWidth * thumbRatio
            let thumbX = progress * (trackWidth - thumbWidth)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(WoadieTheme.borderSubtle)
                Capsule()
                    .fill(WoadieTheme.foregroundSubtle.opacity(0.6))
                    .frame(width: thumbWidth)
                    .offset(x: thumbX)
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 4)
        .animation(.easeOut(duration: 0.15), value: metrics.offsetX)
    }
}
