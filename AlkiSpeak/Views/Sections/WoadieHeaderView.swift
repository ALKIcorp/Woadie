import SwiftUI

struct WoadieHeaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Color.clear
                .frame(width: 92, height: 24)
            Spacer()
            Text("AlkiSpeak")
                .font(WoadieTheme.rounded(size: 13, weight: .semibold))
                .tracking(0.2)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 2)
    }
}
