import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            statusRow
            controlsRow
            inputRow
            chatPanel
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

    private var chatPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.chatItems) { item in
                        HStack {
                            if item.isUser {
                                Spacer(minLength: 0)
                                Text(item.text)
                                    .padding(8)
                                    .background(Color.accentColor.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .frame(maxWidth: 360, alignment: .trailing)
                            } else {
                                Text(item.text)
                                    .padding(8)
                                    .background(Color.gray.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .frame(maxWidth: 360, alignment: .leading)
                                Spacer(minLength: 0)
                            }
                        }
                        .id(item.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 200)
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2)))
            .onChange(of: model.chatItems.count) {
                if let last = model.chatItems.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
