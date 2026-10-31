import SwiftUI

struct WoadieInputRow: View {
    @ObservedObject var model: AppModel
    /// Kept while the Expression menu has focus, so a tag lands at the cursor.
    @State private var selection: TextSelection?

    var body: some View {
        AlkiGlassSurface {
            VStack(alignment: .leading, spacing: 12) {
                WoadieTextEditor(
                    text: Binding(
                        get: { model.inputText },
                        set: { model.inputText = $0 }
                    ),
                    selection: $selection,
                    placeholder: "What should AlkiSpeak say?",
                    isDisabled: !model.canEditText
                )

                if let speakers = model.selectedDialogueSpeakers {
                    Text("DIALOGUE: START EACH LINE WITH " + speakers.map { "\($0.name.uppercased()):" }.joined(separator: " OR ")
                         + " · ADD A NOTE LIKE \(speakers[0].name.uppercased()) (CHEERFUL):")
                        .font(WoadieTheme.mono(size: 9, weight: .medium))
                        .tracking(0.4)
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                }
                HStack {
                    Text("COMMAND RETURN TO SEND")
                        .font(WoadieTheme.mono(size: 9, weight: .medium))
                        .tracking(0.4)
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                    Spacer()
                    if !model.selectedVoiceExpressionTags.isEmpty {
                        Menu {
                            ForEach(model.selectedVoiceExpressionTags, id: \.self) { tag in
                                Button("[\(tag)]") { insert(tag) }
                            }
                        } label: {
                            Label("Expression", systemImage: "face.smiling")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Insert a cue like [Laughter] that this voice performs")
                    }
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

    private func insert(_ tag: String) {
        let range = selection?.characterRange(in: model.inputText)
        let cursor = model.insertExpressionTag(tag, replacing: range)
        let text = model.inputText
        selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: min(cursor, text.count)))
    }
}
