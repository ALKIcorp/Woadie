import SwiftUI

struct WoadieInputRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        AlkiGlassSurface {
            VStack(alignment: .leading, spacing: 12) {
                WoadieTextEditor(
                    text: Binding(
                        get: { model.inputText },
                        set: { model.inputText = $0 }
                    ),
                    placeholder: "What should AlkiSpeak say?",
                    isDisabled: !model.canEditText
                )

                HStack {
                    Text("COMMAND RETURN TO SEND")
                        .font(WoadieTheme.mono(size: 9, weight: .medium))
                        .tracking(0.4)
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                    Spacer()
                    if model.showAddToLog {
                        WoadieButton(
                            title: "Add to Log",
                            systemImage: "plus",
                            variant: .default
                        ) {
                            model.addCurrentToLog()
                        }
                    }
                    WoadieButton(
                        title: "Generate Speech",
                        systemImage: "waveform",
                        variant: .primary
                    ) {
                        model.speak()
                    }
                    .disabled(!model.canSpeak)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .padding(15)
        }
    }
}
