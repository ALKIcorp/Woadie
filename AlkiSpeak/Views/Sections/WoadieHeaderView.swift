import SwiftUI

struct WoadieHeaderView: View {
    var model: AppModel
    var onOpenSettings: () -> Void
    var onOpenStorage: () -> Void
    var onOpenVoices: () -> Void

    var body: some View {
        HStack {
            Spacer()
                .frame(width: 124)

            Spacer()
            Text("AlkiSpeak")
                .font(WoadieTheme.rounded(size: 13, weight: .semibold))
                .tracking(0.2)
            Spacer()

            HStack(spacing: 4) {
                Button {
                    onOpenVoices()
                } label: {
                    Image(systemName: "person.wave.2")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Voices")

                Button {
                    onOpenStorage()
                } label: {
                    Image(systemName: "internaldrive")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Storage dashboard")

                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .frame(width: 124, alignment: .trailing)
        }
        .padding(.horizontal, 2)
    }
}
