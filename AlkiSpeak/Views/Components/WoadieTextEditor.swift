import SwiftUI

struct WoadieTextEditor: View {
    @Binding var text: String
    /// The cursor or selection, so callers can insert at it (e.g. expression tags).
    @Binding var selection: TextSelection?
    let placeholder: String
    let isDisabled: Bool

    init(text: Binding<String>, selection: Binding<TextSelection?> = .constant(nil), placeholder: String, isDisabled: Bool) {
        _text = text
        _selection = selection
        self.placeholder = placeholder
        self.isDisabled = isDisabled
    }

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

            TextEditor(text: $text, selection: $selection)
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

extension TextSelection {
    /// The selected range as character offsets into `text`, or `nil` when the
    /// selection doesn't map onto it (e.g. multiple cursors, stale indices).
    func characterRange(in text: String) -> Range<Int>? {
        guard case .selection(let range) = indices,
              range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex
        else { return nil }
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        return lower..<upper
    }
}
