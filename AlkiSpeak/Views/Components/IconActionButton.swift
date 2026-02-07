import SwiftUI

struct IconActionButton: View {
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? WoadieTheme.foreground : WoadieTheme.foregroundSubtle)
                .frame(width: 26, height: 26)
                .background(hovering ? WoadieTheme.surface : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
