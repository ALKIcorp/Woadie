import SwiftUI

/// A custom circular shape that draws a segment of a circle for the knob track.
struct DialArc: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let clockwise: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: clockwise
        )
        return path
    }
}

/// A high-fidelity SwiftUI rotary dial knob with liquid glass aesthetics.
/// Designed for tactile speed adjustments with a center detent at 1.0x.
struct WoadieLiquidGlassKnob: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double = 1.0
    
    @State private var isDragging: Bool = false
    @State private var startValue: Double = 1.0
    
    private let size: CGFloat = 72
    private let trackWidth: CGFloat = 4.5
    
    var body: some View {
        let currentAngle = angle(for: value)
        
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                
                ZStack {
                    // 1. Base Dial Track (Background slot)
                    DialArc(startAngle: .degrees(135), endAngle: .degrees(45), clockwise: false)
                        .stroke(
                            Color.primary.opacity(0.08),
                            style: StrokeStyle(lineWidth: trackWidth, lineCap: .round)
                        )
                        .frame(width: size - trackWidth, height: size - trackWidth)
                    
                    // 2. Active Progress Arc (From 1.0x center out)
                    if value != defaultValue {
                        activeProgressArc(currentAngle: currentAngle)
                            .stroke(
                                progressGradient,
                                style: StrokeStyle(lineWidth: trackWidth, lineCap: .round)
                            )
                            .frame(width: size - trackWidth, height: size - trackWidth)
                            .shadow(color: WoadieTheme.primary.opacity(0.35), radius: 3, x: 0, y: 0)
                    }
                    
                    // 3. Center Detent Indicator Marker
                    Circle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 3, height: 3)
                        .offset(y: -(size / 2) + trackWidth / 2)
                    
                    // 4. The Glass Knob Body
                    ZStack {
                        // Ambient Drop Shadow
                        Circle()
                            .fill(Color.black.opacity(0.12))
                            .blur(radius: isDragging ? 5 : 3)
                            .offset(y: isDragging ? 3 : 1.5)
                        
                        // Inner Glass Base
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [.white.opacity(0.12), .clear],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            }
                        
                        // Liquid Glass Crescent Highlight (Refraction)
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.24), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: size * 0.58, height: size * 0.58)
                            .offset(x: -size * 0.04, y: -size * 0.04)
                            .mask(Circle())
                        
                        // Shiny Outer Bezel/Rim
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.38),
                                        .white.opacity(0.08),
                                        .black.opacity(0.12)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.2
                            )
                        
                        // 5. Glowing Indicator Dot
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [WoadieTheme.primary, WoadieTheme.primary.opacity(0.8)],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 3
                                )
                            )
                            .frame(width: 5.5, height: 5.5)
                            .shadow(color: WoadieTheme.primary.opacity(0.8), radius: 2.5)
                            .offset(y: -(size * 0.26))
                            .rotationEffect(.degrees(currentAngle))
                    }
                    .frame(width: size * 0.72, height: size * 0.72)
                    .contentShape(Circle())
                    .scaleEffect(isDragging ? 1.04 : 1.0)
                    .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isDragging)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                if !isDragging {
                                    startValue = value
                                    isDragging = true
                                }
                                updateValue(translation: gesture.translation)
                            }
                            .onEnded { _ in
                                isDragging = false
                            }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: size, height: size)
        }
    }
    
    /// Computes the active progress arc shape based on whether value is above or below default.
    private func activeProgressArc(currentAngle: Double) -> DialArc {
        if value < defaultValue {
            // Underclock: Arc from currentAngle to -90 (counter-clockwise)
            return DialArc(startAngle: .degrees(currentAngle), endAngle: .degrees(-90), clockwise: false)
        } else {
            // Overclock: Arc from -90 to currentAngle (clockwise)
            return DialArc(startAngle: .degrees(-90), endAngle: .degrees(currentAngle), clockwise: false)
        }
    }
    
    private var progressGradient: LinearGradient {
        LinearGradient(
            colors: [WoadieTheme.primary, WoadieTheme.primary.opacity(0.85)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    /// Map current speed value to rotary degrees (-135 to 135)
    private func angle(for val: Double) -> Double {
        if val < defaultValue {
            let pct = (val - range.lowerBound) / (defaultValue - range.lowerBound)
            return -135.0 + (pct * 135.0)
        } else {
            let pct = (val - defaultValue) / (range.upperBound - defaultValue)
            return pct * 135.0
        }
    }
    
    /// Update binding value using relative translation (Up/Right to increase, Down/Left to decrease)
    private func updateValue(translation: CGSize) {
        // Dragging UP is a negative translation.height, which increases value.
        // Dragging RIGHT is a positive translation.width, which increases value.
        let deltaY = -Double(translation.height)
        let deltaX = Double(translation.width)
        
        // Combined linear drag delta
        let netTranslation = deltaY + deltaX
        
        // Sensitivity: full range (0.65 to 1.75 = 1.10) over 200 points of drag
        let sensitivity = (range.upperBound - range.lowerBound) / 200.0
        var newValue = startValue + netTranslation * sensitivity
        
        // Tactile snap detent to normal speed (1.0x) if close
        if abs(newValue - defaultValue) < 0.04 {
            newValue = defaultValue
        }
        
        value = min(max(newValue, range.lowerBound), range.upperBound)
    }
}
