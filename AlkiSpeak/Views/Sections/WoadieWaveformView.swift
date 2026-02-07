import SwiftUI

struct WoadieWaveformView: View {
    let isActive: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let midY = size.height * 0.5
                let width = size.width
                let height = size.height

                let baseAmp = isActive ? height * 0.22 : height * 0.08
                let secondaryAmp = baseAmp * 0.55
                let speed = isActive ? 2.2 : 0.8

                var path = Path()
                let points = max(Int(width / 6), 60)

                for i in 0..<points {
                    let x = CGFloat(i) / CGFloat(points - 1) * width
                    let progress = Double(x / width)
                    let wave = sin(progress * .pi * 4 + time * speed) * Double(baseAmp)
                    let mod = sin(progress * .pi * 12 + time * (speed * 0.7)) * Double(secondaryAmp)
                    let y = midY + CGFloat(wave + mod)

                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                let stroke = Gradient(colors: [
                    WoadieTheme.primary.opacity(0.9),
                    WoadieTheme.foregroundSubtle.opacity(0.6)
                ])

                context.addFilter(.blur(radius: isActive ? 4 : 2))
                context.stroke(
                    path,
                    with: .linearGradient(stroke, startPoint: .zero, endPoint: CGPoint(x: width, y: 0)),
                    lineWidth: isActive ? 4 : 2
                )

                context.addFilter(.blur(radius: 0))
                context.stroke(
                    path,
                    with: .linearGradient(stroke, startPoint: .zero, endPoint: CGPoint(x: width, y: 0)),
                    lineWidth: 1.2
                )

                let particleCount = 18
                for index in 0..<particleCount {
                    let phase = (time * (isActive ? 0.25 : 0.1)) + Double(index) / Double(particleCount)
                    let progress = phase.truncatingRemainder(dividingBy: 1)
                    let x = CGFloat(progress) * width
                    let y = midY + CGFloat(sin(progress * .pi * 4 + time * speed) * Double(baseAmp * 0.7))
                    let radius = isActive ? 3.0 : 2.0
                    let opacity = isActive ? 0.85 : 0.35

                    let particle = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    context.fill(particle, with: .color(WoadieTheme.primary.opacity(opacity)))
                }

                let glow = Path(roundedRect: CGRect(x: 0, y: midY - 1, width: width, height: 2), cornerRadius: 1)
                context.fill(glow, with: .color(WoadieTheme.primary.opacity(isActive ? 0.2 : 0.08)))
            }
        }
        .padding(12)
    }
}
