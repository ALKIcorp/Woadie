import SwiftUI

struct VoicePickerView: View {
    @Binding var selection: String
    let selectedLabel: String
    let categories: [(title: String, voices: [VoiceOption])]
    let onStep: (Int) -> Void
    @State private var showingVoices = false

    var body: some View {
        HStack(spacing: 10) {
            Button { onStep(-1) } label: {
                Image(systemName: "chevron.up").frame(width: 24, height: 24)
            }
            Text(selectedLabel.uppercased())
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.18), value: selectedLabel)
                .onLongPressGesture { showingVoices = true }
                .help("Press and hold to show all voices")
            Button { onStep(1) } label: {
                Image(systemName: "chevron.down").frame(width: 24, height: 24)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .font(WoadieTheme.rounded(size: 11, weight: .semibold))
        .background(Color.white.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(WoadieTheme.borderSubtle))
        .frame(maxWidth: 280)
        .sheet(isPresented: $showingVoices) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose Voice")
                    .font(WoadieTheme.rounded(size: 20, weight: .semibold))
                List {
                    ForEach(categories, id: \.title) { category in
                        Section(category.title) {
                            ForEach(category.voices) { option in
                                Button(option.label) {
                                    selection = option.id
                                    showingVoices = false
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(width: 420, height: 440)
            .background(.ultraThinMaterial)
        }
    }
}
