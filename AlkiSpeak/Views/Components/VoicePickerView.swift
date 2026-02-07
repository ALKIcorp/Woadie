import SwiftUI

struct VoicePickerView: View {
    @Binding var selection: String
    let options: [AppModel.VoiceOption]

    var body: some View {
        HStack(spacing: 10) {
            Text("Voice")
                .font(WoadieTheme.mono(size: 11, weight: .medium))
                .foregroundStyle(WoadieTheme.foregroundSubtle)
                .textCase(.uppercase)
                .tracking(1.2)

            Menu {
                ForEach(options) { option in
                    Button(option.label) {
                        selection = option.id
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(selectedLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                }
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
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 260)
        }
    }

    private var selectedLabel: String {
        options.first(where: { $0.id == selection })?.label ?? "Select Voice"
    }
}
