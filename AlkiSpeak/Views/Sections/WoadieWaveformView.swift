import SwiftUI

struct WoadieWaveformView: View {
    let isActive: Bool
    let magnitudes: [Float]

    var body: some View {
        TimelineView(.periodic(from: .now, by: isActive ? 1.0 / 60.0 : 1.0 / 12.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let midY = size.height * 0.5
                let width = size.width
                let height = size.height

                let count = min(128, max(magnitudes.count, 1))
                let spacing = width / CGFloat(count)
                for index in 0..<count {
                    let live = index < magnitudes.count ? CGFloat(magnitudes[index]) : 0
                    let idle = CGFloat(0.08 + 0.05 * sin(time * 1.3 + Double(index) * 0.24))
                    let value = isActive ? max(0.025, live) : idle
                    let barHeight = min(height * 0.9, max(3, value * height * 1.4))
                    let barWidth = max(1.2, spacing * (0.46 + CGFloat(index % 5) * 0.035))
                    let x = CGFloat(index) * spacing + spacing * 0.5
                    let asymmetry = CGFloat((index % 7) - 3) * 0.45
                    let rect = CGRect(x: x - barWidth / 2, y: midY - barHeight * 0.5 + asymmetry, width: barWidth, height: barHeight)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(Color.accentColor.opacity(0.42 + Double(index % 6) * 0.08))
                    )
                }
            }
        }
        .padding(12)
    }
}
