import SwiftUI

struct WoadieBackground: View {
    var body: some View {
        ZStack {
            WoadieTheme.background
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    WoadieTheme.primary.opacity(0.08),
                    WoadieTheme.background.opacity(0)
                ],
                center: .top,
                startRadius: 20,
                endRadius: 420
            )
            .ignoresSafeArea()

            NoiseTexture()
                .opacity(0.05)
                .blendMode(.softLight)
                .ignoresSafeArea()
        }
    }
}

private struct NoiseTexture: View {
    private let image = WoadieTheme.noiseImage

    var body: some View {
        Image(nsImage: image)
            .resizable(resizingMode: .tile)
    }
}
