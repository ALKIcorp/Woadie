import SwiftUI

struct WoadieFooter: View {
    var body: some View {
        Text("Command + Enter to speak • Built with elegance")
            .font(WoadieTheme.mono(size: 10, weight: .medium))
            .foregroundStyle(WoadieTheme.foregroundSubtle.opacity(0.5))
            .textCase(.uppercase)
            .tracking(2)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 10)
    }
}
