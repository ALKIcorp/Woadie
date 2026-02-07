import SwiftUI

struct WoadieControlsBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            WoadieButton(
                title: model.startStopLabel,
                systemImage: "stop.fill",
                variant: .default
            ) {
                model.toggleEngine()
            }
            .disabled(model.status == .warmingUp)
            .keyboardShortcut("r", modifiers: [.command, .shift])

            WoadieButton(
                title: "Refresh Voices",
                systemImage: "arrow.clockwise",
                variant: .default
            ) {
                model.refreshVoices()
            }
            .disabled(model.status != .on)

            Divider()
                .frame(height: 20)
                .overlay(WoadieTheme.border)
                .padding(.horizontal, 4)

            VoicePickerView(
                selection: $model.selectedVoice,
                selectedLabel: model.selectedVoiceLabel,
                categories: model.voiceCategories
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
