import SwiftUI

struct WoadieBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let largestSide = max(proxy.size.width, proxy.size.height)
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: largestSide * 1.12, height: largestSide * 1.12)
                    .blur(radius: largestSide * 0.13)
                    .offset(x: -largestSide * 0.32, y: -largestSide * 0.36)
                Circle()
                    .fill(Color.primary.opacity(0.055))
                    .frame(width: largestSide * 0.92, height: largestSide * 0.92)
                    .blur(radius: largestSide * 0.18)
                    .position(x: proxy.size.width * 0.96, y: proxy.size.height * 0.14)
                LinearGradient(
                    colors: [.white.opacity(0.12), .clear, Color.primary.opacity(0.025)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }
}
