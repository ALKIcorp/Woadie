import SwiftUI

struct WoadieWaveformView: View {
    let isActive: Bool
    let magnitudes: [Float]

    /// Per-bar interpolated heights for smooth animation between data updates.
    @State private var displayBars: [CGFloat] = Array(repeating: 0, count: 128)

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let midY = size.height * 0.5
                let width = size.width
                let height = size.height

                let count = min(128, max(magnitudes.count, 1))
                let spacing = width / CGFloat(count)
                for index in 0..<count {
                    let barValue = index < displayBars.count ? displayBars[index] : 0
                    let barHeight = min(height * 0.6, max(3, barValue * height * 0.75))
                    let barWidth = max(1.2, spacing * (0.46 + CGFloat(index % 5) * 0.035))
                    let x = CGFloat(index) * spacing + spacing * 0.5
                    let asymmetry = isActive ? CGFloat((index % 7) - 3) * 0.45 : 0
                    let rect = CGRect(x: x - barWidth / 2, y: midY - barHeight * 0.5 + asymmetry, width: barWidth, height: barHeight)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(Color.accentColor.opacity(0.42 + Double(index % 6) * 0.08))
                    )
                }
            }
        }
        .padding(12)
        .onChange(of: magnitudes) {
            interpolateBars()
        }
        .onChange(of: isActive) {
            if !isActive {
                withAnimation(.easeOut(duration: 0.35)) {
                    for i in displayBars.indices {
                        displayBars[i] = 0
                    }
                }
            }
        }
    }

    private func interpolateBars() {
        let count = min(128, max(magnitudes.count, 1))
        // Ensure displayBars has the right count
        if displayBars.count != count {
            displayBars = Array(repeating: 0, count: count)
        }
        for index in 0..<count {
            let taper = sin(Double.pi * Double(index) / Double(max(count - 1, 1)))
            let target: CGFloat = isActive
                ? max(0.025, CGFloat(index < magnitudes.count ? magnitudes[index] : 0) * CGFloat(taper))
                : 0
            let current = displayBars[index]
            // Fast attack, gentler release for organic feel
            let lerp: CGFloat = target > current ? 0.45 : 0.25
            displayBars[index] = current + (target - current) * lerp
        }
    }
}
