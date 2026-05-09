import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        Self.applyWindowChrome([window])
    }

    /// Hidden title bar without SwiftUI `.hiddenTitleBar`, which often spins up ViewBridge remote hosting (noisy teardown + debugger artifacts).
    private static func applyWindowChrome(_ windows: [NSWindow]) {
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
        model?.stopEngine()
    }
}

@main
struct AlkiSpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        let store = AppStore()
        let dependencies = AppDependencies.live()
        let m = AppModel(store: store, dependencies: dependencies)
        _model = StateObject(wrappedValue: m)
        appDelegate.model = m
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
