import AppKit
import QuartzCore
import SwiftUI

struct StatusIndicatorView: View {
    @ObservedObject var model: AppModel
    @State private var breathing = false
    @State private var expanded = false

    private var isStarting: Bool { model.status == .starting || model.status == .retrying }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        if model.status == .running || model.status == .idle {
                            // Drawn larger than the dot's 8 pt slot, like the
                            // scaled ring it replaces, without changing layout.
                            PulseRing(color: WoadieTheme.success.opacity(0.35))
                                .frame(width: PulseRing.canvasSize, height: PulseRing.canvasSize)
                                .frame(width: 8, height: 8)
                        }

                        Circle()
                            .fill(dotColor)
                            .frame(width: 8, height: 8)
                            .opacity(isStarting && breathing ? 0.4 : 1.0)
                            // The repeating animation only runs while starting;
                            // leaving that state swaps in a one-shot animation,
                            // which ends the loop instead of letting it run on.
                            .animation(
                                isStarting
                                    ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
                                    : .easeOut(duration: 0.2),
                                value: isStarting && breathing
                            )
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
                // The CPU/RAM rows are only on screen while expanded, so
                // that's the only time they need refreshing.
                .task {
                    while !Task.isCancelled {
                        model.refreshResourceStats()
                        try? await Task.sleep(for: .seconds(5))
                    }
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

/// The engine-ready ring that grows from the status dot and fades out every
/// 2 s. A SwiftUI `repeatForever` animation re-renders the whole window on the
/// main thread every frame, which was most of the app's idle CPU; Core
/// Animation runs the same loop in the render server instead.
private struct PulseRing: NSViewRepresentable {
    static let dotSize: CGFloat = 8
    static let peakScale: CGFloat = 2.2
    /// Room for the ring at its peak scale.
    static let canvasSize: CGFloat = ceil(dotSize * peakScale)

    let color: Color

    func makeNSView(context: Context) -> PulseRingView {
        PulseRingView()
    }

    func updateNSView(_ view: PulseRingView, context: Context) {
        view.color = NSColor(color)
    }
}

private final class PulseRingView: NSView {
    private static let animationKey = "pulse"
    private let ring = CALayer()

    var color: NSColor = .clear {
        didSet { applyColor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        ring.bounds = CGRect(x: 0, y: 0, width: PulseRing.dotSize, height: PulseRing.dotSize)
        ring.cornerRadius = PulseRing.dotSize / 2
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Purely decorative; clicks go to the status button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, ring.animation(forKey: Self.animationKey) == nil {
            ring.add(Self.makePulse(), forKey: Self.animationKey)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.backgroundColor = color.cgColor
        }
    }

    /// Scale 1 → 2.2 and opacity 0.7 → 0 over 2 s with ease-out, restarting
    /// from the beginning each time, matching the previous SwiftUI animation.
    private static func makePulse() -> CAAnimation {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = PulseRing.peakScale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 2
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        return group
    }
}
