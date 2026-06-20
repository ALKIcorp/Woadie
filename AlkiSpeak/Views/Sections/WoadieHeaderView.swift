import SwiftUI

struct WoadieHeaderView: View {
    @ObservedObject var model: AppModel
    var onOpenSettings: () -> Void
    var onOpenStorage: () -> Void

    var body: some View {
        HStack {
            Button {
                onOpenStorage()
            } label: {
                Image(systemName: "internaldrive")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Storage dashboard")
            .frame(width: 92, alignment: .leading)

            Spacer()
            Text("AlkiSpeak")
                .font(WoadieTheme.rounded(size: 13, weight: .semibold))
                .tracking(0.2)
            Spacer()

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 2)
    }
}
