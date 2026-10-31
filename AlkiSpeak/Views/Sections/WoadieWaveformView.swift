import SwiftUI

struct WoadieWaveformView: View {
    let isActive: Bool
    let magnitudes: [Float]

    private static let barCount = 128

    /// Interpolated bar heights, updated every display frame for buttery animation.
    @State private var displayBars: [CGFloat] = Array(repeating: 0, count: barCount)
    /// Snapshot of the target magnitudes, kept separate so we can interpolate
    /// toward them across multiple render frames (not just on data updates).
    @State private var targetBars: [CGFloat] = Array(repeating: 0, count: barCount)
    /// Timestamp of the last render frame for delta-time based interpolation.
    @State private var lastFrameTime: CFTimeInterval = 0
    /// True once every bar has reached its target. The per-frame timeline
    /// pauses then, since each frame would draw the same picture, and resumes
    /// as soon as new targets arrive.
    @State private var isSettled = false

    /// Gap below which a bar counts as having reached its target.
    private static let settleThreshold: CGFloat = 0.0005

    var body: some View {
        TimelineView(.animation(paused: isSettled)) { context in
            Canvas(rendersAsynchronously: true) { ctx, size in
                drawBars(context: ctx, size: size)
            }
            .onChange(of: context.date) {
                advanceInterpolation(date: context.date)
            }
        }
        .padding(12)
        .onChange(of: magnitudes) {
            updateTargets()
            resumeIfNeeded()
        }
        .onChange(of: isActive) {
            if !isActive {
                for i in targetBars.indices {
                    targetBars[i] = 0
                }
            }
            resumeIfNeeded()
        }
    }

    private func resumeIfNeeded() {
        guard isSettled, zip(displayBars, targetBars).contains(where: { abs($0 - $1) > Self.settleThreshold }) else { return }
        // Restart dt from a single frame instead of the whole paused interval.
        lastFrameTime = 0
        isSettled = false
    }

    // MARK: - Target Update (runs when FFT data arrives)

    private func updateTargets() {
        let count = Self.barCount
        for index in 0..<count {
            let raw = index < magnitudes.count ? CGFloat(magnitudes[index]) : 0
            let taper = sin(.pi * CGFloat(index) / CGFloat(max(count - 1, 1)))
            targetBars[index] = isActive ? max(0.025, raw * taper) : 0
        }
    }

    // MARK: - Frame-Driven Interpolation

    /// Called every display frame by the TimelineView, producing smooth
    /// movement even between FFT data updates.
    private func advanceInterpolation(date: Date) {
        let now = CACurrentMediaTime()
        let dt: CGFloat
        if lastFrameTime == 0 {
            dt = 1.0 / 120.0
        } else {
            // Clamp dt to avoid huge jumps after app suspension
            dt = min(CGFloat(now - lastFrameTime), 0.05)
        }
        lastFrameTime = now

        // Exponential decay interpolation using dt so speed is frame-rate
        // independent. Higher `speed` = snappier bars.
        //  factor = 1 - exp(-speed * dt)
        let attackSpeed: CGFloat = 28.0   // fast rise — bars snap up quickly
        let releaseSpeed: CGFloat = 12.0  // slightly gentler fall for organic feel
        let attackFactor = 1 - exp(-attackSpeed * dt)
        let releaseFactor = 1 - exp(-releaseSpeed * dt)

        let count = Self.barCount
        var next = displayBars
        var settled = true
        for i in 0..<count {
            let target = targetBars[i]
            let current = next[i]
            let diff = target - current
            if abs(diff) <= Self.settleThreshold {
                next[i] = target
                continue
            }
            settled = false
            let factor = diff > 0 ? attackFactor : releaseFactor
            next[i] = current + diff * factor
        }
        if next != displayBars {
            displayBars = next
        }
        if settled {
            isSettled = true
        }
    }

    // MARK: - Drawing

    private func drawBars(context: GraphicsContext, size: CGSize) {
        let midY = size.height * 0.5
        let width = size.width
        let height = size.height
        let count = Self.barCount
        let spacing = width / CGFloat(count)

        for index in 0..<count {
            let barValue = displayBars[index]
            let barHeight = min(height * 0.6, max(2.5, barValue * height * 0.75))
            let barWidth = max(1.2, spacing * (0.46 + CGFloat(index % 5) * 0.035))
            let x = CGFloat(index) * spacing + spacing * 0.5
            let asymmetry = isActive ? CGFloat((index % 7) - 3) * 0.45 : 0
            let rect = CGRect(
                x: x - barWidth / 2,
                y: midY - barHeight * 0.5 + asymmetry,
                width: barWidth,
                height: barHeight
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: .color(Color.accentColor.opacity(0.42 + Double(index % 6) * 0.08))
            )
        }
    }
}
