import AppKit
import SwiftUI

enum WindowChromePolicy {
    static let reappliesDuringActivationChanges = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var selectedTextServiceProvider: SelectedTextServiceProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.consoleTrace("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.regular)
        installSelectedTextServiceProvider()
        DispatchQueue.main.async {
            self.applyWindowChrome(NSApplication.shared.windows)
        }
    }

    func installSelectedTextServiceProvider() {
        guard let model else { return }
        let provider = SelectedTextServiceProvider(model: model)
        selectedTextServiceProvider = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
        Self.consoleTrace("selected text service provider installed")
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
        false
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
        WindowGroup("AlkiSpeak", id: "main") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(model.appearance.preferredColorScheme)
                .onChange(of: scenePhase) { _, phase in
                    guard !AppConfig.isRunningUnitTests else { return }
                    switch phase {
                    case .active:
                        model.startEngine()
                    case .inactive, .background:
                        break
                    @unknown default:
                        break
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

        MenuBarExtra("AlkiSpeak", systemImage: menuBarSystemImage) {
            MenuBarQuickSpeakView(model: model)
                .preferredColorScheme(model.appearance.preferredColorScheme)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSystemImage: String {
        switch model.playback.state {
        case .playing, .preparing:
            return "waveform.circle.fill"
        case .paused:
            return "pause.circle"
        default:
            return "waveform.circle"
        }
    }
}

private struct MenuBarQuickSpeakView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var quickText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AlkiSpeak")
                        .font(WoadieTheme.rounded(size: 16, weight: .semibold))
                    Text(model.engineStatusLabel)
                        .font(WoadieTheme.mono(size: 10, weight: .medium))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                }
                Spacer()
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.playback.state == .playing ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(model.playback.bufferedDuration <= 0 && model.playback.state != .playing)
                .help(model.playback.state == .playing ? "Pause playback" : "Play cached audio")
            }

            TextEditor(text: $quickText)
                .font(WoadieTheme.rounded(size: 13, weight: .regular))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 96)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(WoadieTheme.borderSubtle)
                )

            HStack {
                Button("Open App") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)

                Spacer()

                WoadieButton(title: "Speak", systemImage: "waveform", variant: .primary) {
                    model.speakExternalText(quickText)
                    quickText = ""
                }
                .disabled(quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !model.message.isEmpty {
                Text(model.message)
                    .font(WoadieTheme.mono(size: 10, weight: .medium))
                    .foregroundStyle(WoadieTheme.warning)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(width: 320)
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
