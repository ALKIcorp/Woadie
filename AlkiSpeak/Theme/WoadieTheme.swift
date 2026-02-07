import SwiftUI
import AppKit

enum WoadieTheme {
    static let background = Color(red: 0.04, green: 0.06, blue: 0.08)
    static let surface = Color(red: 0.08, green: 0.1, blue: 0.13)
    static let surfaceGlass = Color(red: 0.1, green: 0.12, blue: 0.15).opacity(0.8)
    static let foreground = Color(red: 0.93, green: 0.95, blue: 0.97)
    static let foregroundMuted = Color(red: 0.55, green: 0.6, blue: 0.67)
    static let foregroundSubtle = Color(red: 0.36, green: 0.4, blue: 0.46)

    static let primary = Color(red: 0.17, green: 0.7, blue: 0.65)
    static let primaryForeground = Color(red: 0.04, green: 0.06, blue: 0.08)
    static let success = Color(red: 0.2, green: 0.7, blue: 0.45)
    static let warning = Color(red: 0.95, green: 0.64, blue: 0.26)
    static let destructive = Color(red: 0.9, green: 0.3, blue: 0.3)

    static let border = Color(red: 0.18, green: 0.2, blue: 0.24)
    static let borderSubtle = Color(red: 0.14, green: 0.16, blue: 0.2)

    static func mono(size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static let noiseImage: NSImage = {
        let size = NSSize(width: 140, height: 140)
        let image = NSImage(size: size)
        image.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        for _ in 0..<900 {
            let x = CGFloat.random(in: 0..<size.width)
            let y = CGFloat.random(in: 0..<size.height)
            let alpha = CGFloat.random(in: 0.02...0.08)
            context.setFillColor(NSColor(white: 1.0, alpha: alpha).cgColor)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }()
}
