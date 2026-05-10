import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.consoleTrace("applicationDidFinishLaunching")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        DispatchQueue.main.async {
            Self.applyWindowChrome(NSApplication.shared.windows)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Self.consoleTrace("windowDidBecomeKey title=\(window.title) isVisible=\(window.isVisible)")
        Self.applyWindowChrome([window])
    }

    /// Hidden title bar without SwiftUI `.hiddenTitleBar`, which often spins up ViewBridge remote hosting (noisy teardown + debugger artifacts).
    private static func applyWindowChrome(_ windows: [NSWindow]) {
        consoleTrace("applyWindowChrome windowCount=\(windows.count)")
        for window in windows where window.styleMask.contains(.titled) {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            if #available(macOS 11.0, *) {
                window.toolbarStyle = .unified
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.consoleTrace("applicationWillTerminate calling model.stopEngine()")
        model?.stopEngine()
    }

    private static func consoleTrace(_ message: String, function: StaticString = #function, line: UInt = #line) {
        NSLog("[Woadie][AppDelegate][\(function):\(line)] \(message)")
    }
}

@main
struct AlkiSpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        NSLog("[Woadie][AlkiSpeakApp][init] Creating app store and live dependencies")
        let store = AppStore()
        let dependencies = AppDependencies.live()
        let m = AppModel(store: store, dependencies: dependencies)
        _model = StateObject(wrappedValue: m)
        appDelegate.model = m
        NSLog("[Woadie][AlkiSpeakApp][init] AppModel attached to AppDelegate")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
