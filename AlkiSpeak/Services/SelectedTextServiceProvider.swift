import AppKit

@MainActor
final class SelectedTextServiceProvider: NSObject {
    weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    @objc
    func speakSelection(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let selectedText = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !selectedText.isEmpty
        else {
            error.pointee = "Select text before using Speak with AlkiSpeak."
            return
        }

        guard let model else {
            error.pointee = "AlkiSpeak is not ready."
            return
        }

        model.speakExternalText(selectedText)
    }
}
