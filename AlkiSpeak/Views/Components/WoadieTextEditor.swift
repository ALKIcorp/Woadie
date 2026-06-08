import SwiftUI

struct WoadieTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let isDisabled: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(WoadieTheme.rounded(size: 14, weight: .regular))
                .foregroundStyle(WoadieTheme.foreground)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 58, idealHeight: 76, maxHeight: 150)
                .background(Color.clear)
                .disabled(isDisabled)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(WoadieTheme.rounded(size: 14, weight: .regular))
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 10)
            }
        }
    }
}
