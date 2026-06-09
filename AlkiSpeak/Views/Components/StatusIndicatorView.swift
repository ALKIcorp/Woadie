import SwiftUI

struct StatusIndicatorView: View {
    @ObservedObject var model: AppModel
    @State private var pulse = false
    @State private var breathing = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        if model.status == .running || model.status == .idle {
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
                            .opacity((model.status == .starting || model.status == .retrying) ? (breathing ? 0.4 : 1.0) : 1.0)
                            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: breathing)
                            .onAppear { breathing = true }
                    }

                    Text(model.engineStatusLabel.uppercased())
                        .font(WoadieTheme.mono(size: 10, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(dotColor.opacity(0.10)))
                .overlay(Capsule().strokeBorder(dotColor.opacity(0.24)))
            }
            .buttonStyle(.plain)

            if expanded {
                AlkiGlassSurface(cornerRadius: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let message = model.store.playback.statusMessage {
                            Label(message, systemImage: "hourglass")
                                .foregroundStyle(WoadieTheme.warning)
                        }
                        ForEach(model.store.engineDiagnostics.prefix(4)) { diagnostic in
                            Text(diagnostic.message)
                                .lineLimit(2)
                        }
                        resourceRow("CPU", value: model.store.dashboardTelemetry.resourceSnapshot.cpuPercent ?? 0, suffix: "%")
                        resourceRow(
                            "RAM",
                            value: Double(model.store.dashboardTelemetry.resourceSnapshot.memoryBytes ?? 0) / 1_048_576,
                            suffix: " MB"
                        )
                        WoadieButton(title: "Restart Engine", variant: .primary) {
                            model.restartEngine()
                        }
                    }
                    .font(WoadieTheme.mono(size: 10, weight: .medium))
                    .padding(14)
                    .frame(width: 320, alignment: .leading)
                }
            }
        }
    }

    private func resourceRow(_ title: String, value: Double, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.1f%@", value, suffix))
            }
            ProgressView(value: min(max(value / (title == "CPU" ? 100 : 16_384), 0), 1))
        }
    }

    private var dotColor: Color {
        switch model.status {
        case .running, .idle:
            return WoadieTheme.success
        case .starting, .busy, .retrying:
            return WoadieTheme.warning
        case .degraded, .timedOut, .stalled:
            return .yellow
        case .stopped, .failed:
            return WoadieTheme.destructive
        }
    }
}
