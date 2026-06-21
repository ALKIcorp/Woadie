import AppKit

enum SelectedTextReader {
    /// Whether the app currently holds Accessibility (AX) permission. This is a
    /// pure check that never shows a system dialog, so it is safe to call on every
    /// invocation. Triggering the permission prompt is handled separately and
    /// deliberately (see `AppModel.requestAccessibilityAccessOnce`) so we never
    /// stack duplicate dialogs on the hot path.
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    @MainActor
    static func readFocusedSelection() async -> String? {
        if let text = readAccessibilitySelection() {
            return text
        }

        if AXIsProcessTrusted(), let previousApp = FrontmostAppTracker.shared.previousApp {
            let pasteboard = NSPasteboard.general
            
            let savedItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
                let newItem = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        newItem.setData(data, forType: type)
                    }
                }
                return newItem
            }
            
            let changeCount = pasteboard.changeCount
            
            previousApp.activate(options: [])
            try? await Task.sleep(nanoseconds: 50_000_000)
            
            let source = CGEventSource(stateID: .hidSystemState)
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
            cmdDown?.flags = .maskCommand
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
            cmdUp?.flags = .maskCommand
            
            cmdDown?.post(tap: .cghidEventTap)
            cmdUp?.post(tap: .cghidEventTap)
            
            var copiedText: String?
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if pasteboard.changeCount != changeCount {
                    copiedText = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    break
                }
            }
            
            if let savedItems {
                pasteboard.clearContents()
                pasteboard.writeObjects(savedItems)
            }
            
            if let copiedText {
                return copiedText
            }
        }

        return NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    @MainActor
    private static func readAccessibilitySelection() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        guard let targetApp = FrontmostAppTracker.shared.previousApp ?? NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedElement = focusedValue
        else { return nil }

        var selectedTextValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        ) == .success,
              let selectedText = selectedTextValue as? String
        else { return nil }

        return selectedText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

/// Tracks the most recent app the user was working in, so that after a Service
/// invocation activates AlkiSpeak we can hand focus straight back to it instead
/// of letting macOS pick an arbitrary window (which made the user's page "go away").
@MainActor
final class FrontmostAppTracker {
    static let shared = FrontmostAppTracker()

    private(set) var previousApp: NSRunningApplication?
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return }
            MainActor.assumeIsolated {
                self?.previousApp = app
            }
        }
    }

    /// Returns focus to the app the user was last in before AlkiSpeak was activated.
    func returnFocusToPreviousApp() {
        if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate(options: [])
        } else {
            NSApp.hide(nil)
        }
    }
}

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

        // Speak in the background. macOS activates the provider app when a Service
        // is invoked, which surfaces our window and steals focus from the app the
        // user is working in. Hand activation straight back to the app they came
        // from so their page stays put while audio keeps playing.
        DispatchQueue.main.async {
            FrontmostAppTracker.shared.returnFocusToPreviousApp()
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
