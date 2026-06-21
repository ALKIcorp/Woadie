import SwiftUI

struct WoadieTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let isDisabled: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TextEditor(text: .constant(placeholder))
                    .font(WoadieTheme.rounded(size: 14, weight: .regular))
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(minHeight: 58, idealHeight: 76, maxHeight: 150)
                    .background(Color.clear)
                    .disabled(true)
                    .focusable(false)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(WoadieTheme.rounded(size: 14, weight: .regular))
                .foregroundStyle(WoadieTheme.foreground)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 58, idealHeight: 76, maxHeight: 150)
                .background(Color.clear)
                .disabled(isDisabled)
        }
    }
}
