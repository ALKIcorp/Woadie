import SwiftUI

struct WoadiePlaybackPanel: View {
    let isPlaying: Bool
    let onStop: () -> Void

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

                WoadieWaveformView(isActive: isPlaying)
                    .frame(height: 120)
                    .background(WoadieTheme.surface.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(WoadieTheme.borderSubtle, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
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
