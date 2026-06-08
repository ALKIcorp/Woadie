import SwiftUI

struct WoadieControlsBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            WoadieButton(
                title: model.startStopLabel,
                systemImage: model.startStopSystemImage,
                variant: .default
            ) {
                model.toggleEngine()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            WoadieButton(
                title: "Refresh Voices",
                systemImage: "arrow.clockwise",
                variant: .default
            ) {
                model.refreshVoices()
            }
            .disabled(!model.status.isAvailableForRemoteSpeech)

            Divider()
                .frame(height: 20)
                .overlay(WoadieTheme.border)
                .padding(.horizontal, 4)

            VoicePickerView(
                selection: Binding(
                    get: { model.selectedVoice },
                    set: { model.selectedVoice = $0 }
                ),
                selectedLabel: model.selectedVoiceLabel,
                categories: model.voiceCategories,
                onStep: model.cycleVoice
            )
        }
        .padding(12)
        .background(WoadieTheme.surface.opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(WoadieTheme.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
