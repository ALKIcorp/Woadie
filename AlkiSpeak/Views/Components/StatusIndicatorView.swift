import SwiftUI

struct StatusIndicatorView: View {
    let status: EngineStatus
    let label: String
    @State private var pulse = false
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if status == .on {
                    Circle()
                        .fill(WoadieTheme.success.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .scaleEffect(pulse ? 2.2 : 1.0)
                        .opacity(pulse ? 0 : 0.7)
                        .animation(.easeOut(duration: 2).repeatForever(autoreverses: false), value: pulse)
                        .onAppear { pulse = true }
                }

                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .opacity(status == .warmingUp ? (breathing ? 0.4 : 1.0) : 1.0)
                    .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: breathing)
                    .onAppear { breathing = true }
            }

            Text(label)
                .font(WoadieTheme.mono(size: 11, weight: .medium))
                .foregroundStyle(textColor)
                .textCase(.uppercase)
                .tracking(1.1)
        }
    }

    private var dotColor: Color {
        switch status {
        case .on:
            return WoadieTheme.success
        case .off:
            return WoadieTheme.foregroundSubtle
        case .warmingUp:
            return WoadieTheme.warning
        case .error:
            return WoadieTheme.destructive
        }
    }

    private var textColor: Color {
        switch status {
        case .on:
            return WoadieTheme.success
        case .off:
            return WoadieTheme.foregroundSubtle
        case .warmingUp:
            return WoadieTheme.warning
        case .error:
            return WoadieTheme.destructive
        }
    }
}
