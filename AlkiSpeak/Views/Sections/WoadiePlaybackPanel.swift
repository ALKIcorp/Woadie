import SwiftUI

struct WoadiePlaybackPanel: View {
    @ObservedObject var model: AppModel
    let onStop: () -> Void
    private var isPlaying: Bool { model.playback.state == .playing || model.playback.state == .preparing }

    var body: some View {
        HStack(spacing: 16) {
            WoadieCDControl(isPlaying: isPlaying, onStop: onStop)
                .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(isPlaying ? "Speaking" : "Idle")
                        .font(WoadieTheme.mono(size: 11, weight: .medium))
                        .foregroundStyle(isPlaying ? WoadieTheme.success : WoadieTheme.foregroundSubtle)
                        .textCase(.uppercase)
                        .tracking(1.2)

                    if isPlaying {
                        Text("Live")
                            .font(WoadieTheme.mono(size: 10, weight: .medium))
                            .foregroundStyle(WoadieTheme.primaryForeground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(WoadieTheme.primary)
                            .clipShape(Capsule())
                    }
                }

                WoadieWaveformView(isActive: isPlaying, magnitudes: model.fftMagnitudes)
                    .frame(height: 78)
                    .background(WoadieTheme.surface.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(WoadieTheme.borderSubtle, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                ProgressiveScrubber(model: model)
                HStack(spacing: 8) {
                    ForEach([-30, -15, -5, 5, 15, 30], id: \.self) { seconds in
                        Button(seconds > 0 ? "+\(seconds)s" : "\(seconds)s") { model.skip(by: Double(seconds)) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!model.canSkip(by: Double(seconds)))
                    }
                    if let status = model.playback.statusMessage {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(WoadieTheme.surface.opacity(0.35))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(WoadieTheme.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
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
    let onStop: () -> Void
    @State private var rotation: Double = 0

    var body: some View {
        Button(action: onStop) {
            ZStack {
                Circle()
                    .fill(WoadieTheme.surface)
                Circle()
                    .stroke(WoadieTheme.border, lineWidth: 2)

                Circle()
                    .stroke(WoadieTheme.primary.opacity(0.6), lineWidth: 3)
                    .padding(6)
                    .rotationEffect(.degrees(rotation))
                    .animation(isPlaying ? .linear(duration: 3).repeatForever(autoreverses: false) : .default, value: rotation)

                Circle()
                    .fill(WoadieTheme.background)
                    .frame(width: 18, height: 18)

                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isPlaying ? WoadieTheme.destructive : WoadieTheme.foregroundSubtle)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            rotation = 360
        }
        .help("Stop playback")
    }
}
