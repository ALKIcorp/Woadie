import AppKit

enum SelectedTextReadResult: Equatable {
    case selected(String)
    case permissionRequired
    case noSelection
}

@MainActor
protocol SelectedTextReading: AnyObject {
    func readFocusedSelection() async -> SelectedTextReadResult
    func requestAccessibilityPrompt()
    func openAccessibilitySettings()
}

@MainActor
final class SelectedTextReader: SelectedTextReading {
    struct PasteboardSnapshot {
        private let items: [NSPasteboardItem]

        init(pasteboard: NSPasteboard) {
            items = pasteboard.pasteboardItems?.map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        copy.setData(data, forType: type)
                    }
                }
                return copy
            } ?? []
        }

        /// Restores only while the pasteboard still contains the copy made by
        /// this invocation. A later user/app copy must always win.
        @discardableResult
        func restore(to pasteboard: NSPasteboard, ifUnchangedSince expectedChangeCount: Int) -> Bool {
            guard pasteboard.changeCount == expectedChangeCount else { return false }
            pasteboard.clearContents()
            if !items.isEmpty {
                pasteboard.writeObjects(items)
            }
            return true
        }
    }

    struct FreshPasteboardRead {
        let text: String?
        let changeCount: Int
    }

    /// Whether the app currently holds Accessibility (AX) permission. This is a
    /// pure check that never shows a system dialog, so it is safe to call on every
    /// invocation.
    private var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    func readFocusedSelection() async -> SelectedTextReadResult {
        guard isAccessibilityTrusted else { return .permissionRequired }
        guard let targetApp = FrontmostAppTracker.shared.previousApp,
              targetApp.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return .noSelection }

        if let text = readAccessibilitySelection(from: targetApp) {
            return .selected(text)
        }

        if let text = await copySelection(from: targetApp) {
            return .selected(text)
        }
        return .noSelection
    }

    func requestAccessibilityPrompt() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func readAccessibilitySelection(from targetApp: NSRunningApplication) -> String? {
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

    private func copySelection(from targetApp: NSRunningApplication) async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let baselineChangeCount = pasteboard.changeCount

        targetApp.activate(options: [])
        for _ in 0..<12 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp.processIdentifier {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp.processIdentifier else {
            return nil
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        commandDown?.flags = .maskCommand
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        commandUp?.flags = .maskCommand
        commandDown?.post(tap: .cghidEventTap)
        commandUp?.post(tap: .cghidEventTap)

        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(50))
            guard let freshRead = Self.freshRead(from: pasteboard, after: baselineChangeCount) else {
                continue
            }
            snapshot.restore(to: pasteboard, ifUnchangedSince: freshRead.changeCount)
            return freshRead.text
        }
        return nil
    }

    /// Returns content only after ownership changed during this invocation. It
    /// deliberately never treats the pre-existing general pasteboard as selected text.
    static func freshRead(from pasteboard: NSPasteboard, after baselineChangeCount: Int) -> FreshPasteboardRead? {
        let observedChangeCount = pasteboard.changeCount
        guard observedChangeCount != baselineChangeCount else { return nil }
        let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard pasteboard.changeCount == observedChangeCount else { return nil }
        return FreshPasteboardRead(text: text, changeCount: observedChangeCount)
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
