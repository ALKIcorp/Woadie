import SwiftUI

struct WoadieHeaderView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 14) {
                WoadieLogo()
                Divider()
                    .frame(height: 16)
                    .overlay(WoadieTheme.border)
                StatusIndicatorView(status: model.status, label: statusLabel)
            }
            Spacer()
            HStack(spacing: 6) {
                Text("Gen:")
                    .foregroundStyle(WoadieTheme.foregroundSubtle.opacity(0.7))
                Text(model.lastLatencyMsText)
                    .foregroundStyle(WoadieTheme.foregroundMuted)
            }
            .font(WoadieTheme.mono(size: 11, weight: .medium))
            .textCase(.uppercase)
        }
    }

    private var statusLabel: String {
        switch model.status {
        case .warmingUp:
            return "Starting..."
        case .on:
            return "Engine ON"
        case .off:
            return "Engine OFF"
        case .error:
            return "Engine Error"
        }
    }
}

private struct WoadieLogo: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(WoadieTheme.primary)
                Circle()
                    .fill(WoadieTheme.primary.opacity(0.25))
                    .blur(radius: 8)
                    .frame(width: 24, height: 24)
            }
            Text("Woadie")
                .font(WoadieTheme.mono(size: 17, weight: .semibold))
                .foregroundStyle(WoadieTheme.foreground)
        }
    }
}
