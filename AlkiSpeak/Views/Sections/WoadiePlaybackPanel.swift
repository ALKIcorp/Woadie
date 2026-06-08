import SwiftUI

struct WoadiePlaybackPanel: View {
    @ObservedObject var model: AppModel
    let onTogglePlayback: () -> Void
    private var isPlaying: Bool { model.playback.state == .playing || model.playback.state == .preparing }
    private var hasPlayableClip: Bool { model.playback.bufferedDuration > 0 }
    private var statusLabel: String {
        switch model.playback.state {
        case .playing, .preparing: return "Speaking"
        case .paused: return "Paused"
        case .stopped where hasPlayableClip: return "Ready"
        default: return "Idle"
        }
    }

    var body: some View {
        AlkiGlassSurface {
            VStack(alignment: .leading, spacing: 16) {
                Text("PLAYBACK")
                    .font(WoadieTheme.mono(size: 9, weight: .semibold))
                    .tracking(1.55)
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
                Text("Transport")
                    .font(WoadieTheme.rounded(size: 20, weight: .medium))

                Spacer(minLength: 8)

                HStack {
                    Button { model.skip(by: -10) } label: {
                        Label("10", systemImage: "gobackward.10").labelStyle(.iconOnly)
                    }
                    .disabled(!model.canSkip(by: -10))
                    Spacer()
                    WoadieCDControl(
                        isPlaying: isPlaying,
                        isEnabled: hasPlayableClip || isPlaying,
                        onTogglePlayback: onTogglePlayback
                    )
                    .frame(width: 72, height: 72)
                    Spacer()
                    Button { model.skip(by: 10) } label: {
                        Label("10", systemImage: "goforward.10").labelStyle(.iconOnly)
                    }
                    .disabled(!model.canSkip(by: 10))
                }
                .buttonStyle(.plain)
                .font(.system(size: 21, weight: .medium))

                Spacer(minLength: 8)
                ProgressiveScrubber(model: model)
                HStack {
                    Text(format(model.playback.elapsedTime))
                    Spacer()
                    Text(format(model.playback.duration ?? 0))
                }
                .font(WoadieTheme.mono(size: 10, weight: .medium))
                .foregroundStyle(WoadieTheme.foregroundSubtle)

                HStack(spacing: 8) {
                    metric("CPU", value: model.store.dashboardTelemetry.resourceSnapshot.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "-")
                    metric("RAM", value: model.store.dashboardTelemetry.resourceSnapshot.memoryBytes.map {
                        ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
                    } ?? "-")
                }

                if let status = model.playback.statusMessage {
                    Text(status)
                        .font(WoadieTheme.mono(size: 10, weight: .medium))
                        .foregroundStyle(WoadieTheme.warning)
                }
            }
            .padding(20)
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(WoadieTheme.mono(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(WoadieTheme.foregroundSubtle)
            Text(value)
                .font(WoadieTheme.rounded(size: 14, weight: .semibold))
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WoadieTheme.borderSubtle))
    }

    private func format(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

private struct ProgressiveScrubber: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let total = max(model.playback.duration ?? 0, 0.1)
        let buffered = min(1, model.playback.bufferedDuration / total)
        let played = min(1, model.playback.elapsedTime / total)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(Color.secondary.opacity(0.45)).frame(width: proxy.size.width * buffered)
                Capsule().fill(Color.accentColor).frame(width: proxy.size.width * played)
                Circle().fill(Color.accentColor).frame(width: 12, height: 12).offset(x: max(0, proxy.size.width * played - 6))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                model.seek(to: total * min(1, max(0, value.location.x / proxy.size.width)))
            })
        }
        .frame(height: 12)
        .accessibilityLabel("Playback position")
    }
}

private struct WoadieCDControl: View {
    let isPlaying: Bool
    let isEnabled: Bool
    let onTogglePlayback: () -> Void
    @State private var rotation: Double = 0

    var body: some View {
        Button(action: onTogglePlayback) {
            ZStack {
                Circle()
                    .fill(Color.primary)
                Circle()
                    .stroke(WoadieTheme.border, lineWidth: 2)

                Circle()
                    .stroke(WoadieTheme.primary.opacity(0.6), lineWidth: 3)
                    .padding(6)
                    .rotationEffect(.degrees(rotation))
                    .animation(isPlaying ? .linear(duration: 3).repeatForever(autoreverses: false) : .default, value: rotation)

                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 18, height: 18)

                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onAppear {
            rotation = 360
        }
        .help(isPlaying ? "Pause playback" : "Play cached audio")
    }
}
