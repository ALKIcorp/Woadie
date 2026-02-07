import SwiftUI

struct WoadieTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let isDisabled: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(WoadieTheme.mono(size: 13, weight: .regular))
                .foregroundStyle(WoadieTheme.foreground)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 68)
                .background(WoadieTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(WoadieTheme.borderSubtle, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(isDisabled)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(WoadieTheme.mono(size: 13, weight: .regular))
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
        }
    }
}
