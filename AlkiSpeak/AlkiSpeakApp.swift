import AppKit
import SwiftUI

enum WindowChromePolicy {
    static let reappliesDuringActivationChanges = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.consoleTrace("applicationDidFinishLaunching")
        DispatchQueue.main.async {
            self.applyWindowChrome(NSApplication.shared.windows)
        }
    }

    /// Hidden title bar without SwiftUI `.hiddenTitleBar`, which often spins up ViewBridge remote hosting (noisy teardown + debugger artifacts).
    private func applyWindowChrome(_ windows: [NSWindow]) {
        Self.consoleTrace("applyWindowChrome windowCount=\(windows.count)")
        for window in windows where window.styleMask.contains(.titled) {
            window.backgroundColor = .clear
            window.isOpaque = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarSeparatorStyle = .none
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.consoleTrace("applicationWillTerminate calling model.stopEngine()")
        model?.stopEngine()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private static func consoleTrace(_ message: String, function: StaticString = #function, line: UInt = #line) {
        NSLog("[Woadie][AppDelegate][\(function):\(line)] \(message)")
    }
}

@main
struct AlkiSpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
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
                .preferredColorScheme(model.appearance.preferredColorScheme)
                .onChange(of: scenePhase) { _, phase in
                    guard !AppConfig.isRunningUnitTests else { return }
                    switch phase {
                    case .active:
                        model.startEngine()
                    case .inactive, .background:
                        model.stopEngine()
                    @unknown default:
                        model.stopEngine()
                    }
                }
        }
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Export") {
                    model.exportSelectedEntry()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selectedLogEntry == nil)

                Button("Import") {
                    model.importSpeechEntry()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(model.appearance.preferredColorScheme)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Picker("Appearance", selection: Binding(
                get: { model.appearance },
                set: { model.setAppearance($0) }
            )) {
                ForEach(AppAppearance.allCases, id: \.self) { appearance in
                    Text(appearance.label).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(24)
        .frame(width: 360)
    }
}
