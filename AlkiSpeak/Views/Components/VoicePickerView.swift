import SwiftUI

struct VoicePickerView: View {
    @Binding var selection: String
    let selectedLabel: String
    let categories: [(title: String, voices: [VoiceOption])]
    let onStep: (Int) -> Void
    @State private var showingVoices = false

    var body: some View {
        HStack(spacing: 10) {
            Text("Voice")
                .font(WoadieTheme.mono(size: 11, weight: .medium))
                .foregroundStyle(WoadieTheme.foregroundSubtle)
                .textCase(.uppercase)
                .tracking(1.2)

            HStack(spacing: 8) {
                Button { onStep(-1) } label: {
                    Image(systemName: "triangle.fill").font(.system(size: 9))
                }
                Text(selectedLabel)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.18), value: selectedLabel)
                    .onLongPressGesture { showingVoices = true }
                    .help("Press and hold to show all voices")
                Button { onStep(1) } label: {
                    Image(systemName: "triangle.fill").font(.system(size: 9)).rotationEffect(.degrees(180))
                }
            }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .font(WoadieTheme.mono(size: 12, weight: .medium))
                .foregroundStyle(WoadieTheme.foreground)
                .background(WoadieTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(WoadieTheme.borderSubtle, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 260)
        }
        .sheet(isPresented: $showingVoices) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose Voice").font(.headline)
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
        }
    }
}
