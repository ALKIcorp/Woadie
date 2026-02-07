import SwiftUI

struct WoadieInputRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WoadieTextEditor(
                text: $model.inputText,
                placeholder: "Enter text to speak...",
                isDisabled: model.status != .on
            )

            WoadieButton(
                title: "Speak",
                systemImage: "mic.fill",
                variant: .primary
            ) {
                model.speak()
            }
            .disabled(!model.canSpeak)
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }
}
