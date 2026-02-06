import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            statusRow
            controlsRow
            inputRow
            if !model.message.isEmpty {
                Text(model.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 220)
    }

    private var statusRow: some View {
        HStack {
            Text("Engine: \(model.status.label)")
                .font(.headline)
                .foregroundStyle(model.status.color)
            Spacer()
            Text("Gen: \(model.lastLatencyMsText)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 10) {
            Button(model.startStopLabel) {
                model.toggleEngine()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("Refresh Voices") {
                model.refreshVoices()
            }
            .disabled(model.status != .on)

            Picker("Voice", selection: $model.selectedVoice) {
                ForEach(model.voices, id: \.self) { voice in
                    Text(voice).tag(voice)
                }
            }
            .frame(width: 220)
        }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            TextField("Type text and press Enter...", text: $model.inputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    model.speak()
                }

            Button("Speak") {
                model.speak()
            }
            .disabled(!model.canSpeak)
            .keyboardShortcut(.defaultAction)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
