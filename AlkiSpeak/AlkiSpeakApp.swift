import AppKit
import SwiftUI

enum WindowChromePolicy {
    static let reappliesDuringActivationChanges = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var selectedTextServiceProvider: SelectedTextServiceProvider?
    private var speechHUD: SpeechHUDController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.consoleTrace("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.regular)
        FrontmostAppTracker.shared.start()
        installSelectedTextServiceProvider()
        installGlobalHotKeys()
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

    /// System-wide shortcuts that speak the selection (or stop) and pause or
    /// resume, without opening the window.
    func installGlobalHotKeys() {
        guard let model, !AppConfig.isRunningUnitTests else { return }
        let hud = SpeechHUDController(model: model)
        speechHUD = hud
        GlobalHotKeyService.shared.start(handlers: [
            .speakOrStop: {
                Task { @MainActor in
                    hud.show(await model.handleSpeakHotKey())
                }
            },
            .pauseOrResume: {
                model.handlePauseHotKey()
            }
        ])
        Self.consoleTrace("global hot keys installed")
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
        model?.savePendingTuning()
        model?.saveBookPosition()
        model?.stopEngine()
        model?.shutDownLocalVoiceServer()
    }

    /// Files opened from Finder ("Open With", or dropped on the Dock icon).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if url.isFileURL {
            model?.importDocument(at: url)
        } else {
            model?.importWebPage(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private static func consoleTrace(_ message: String, function: StaticString = #function, line: UInt = #line) {
        guard AppConfig.isVerboseConsoleTracingEnabled else { return }
        NSLog("[Woadie][AppDelegate][\(function):\(line)] \(message)")
    }
}

@main
struct AlkiSpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    // Held in `@State`, not `@StateObject`, so the scene body doesn't observe
    // the model: every store change used to re-run it and redraw the
    // menu-bar icon. Views that need updates observe the model themselves.
    @State private var model: AppModel

    init() {
        if AppConfig.isVerboseConsoleTracingEnabled {
            NSLog("[Woadie][AlkiSpeakApp][init] Creating app store and live dependencies")
        }
        let store = AppStore()
        let dependencies = AppDependencies.live()
        let m = AppModel(store: store, dependencies: dependencies)
        _model = State(initialValue: m)
        appDelegate.model = m
        if AppConfig.isVerboseConsoleTracingEnabled {
            NSLog("[Woadie][AlkiSpeakApp][init] AppModel attached to AppDelegate")
        }
    }

    var body: some Scene {
        WindowGroup("AlkiSpeak", id: "main") {
            AppearanceRoot(model: model) {
                ContentView()
                    .environment(model)
            }
            .onChange(of: scenePhase) { _, phase in
                guard !AppConfig.isRunningUnitTests else { return }
                switch phase {
                case .active:
                    model.startEngineIfNeeded()
                case .inactive, .background:
                    break
                @unknown default:
                    break
                }
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Document…") { model.openDocument() }
                    .keyboardShortcut("o")
                Button("Speak Clipboard") { model.speakClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .control])
            }
            CommandGroup(after: .saveItem) {
                ExportCommandButton(model: model)

                Button("Import") {
                    model.importSpeechEntry()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        Settings {
            AppearanceRoot(model: model) {
                SettingsView(model: model)
            }
        }

        MenuBarExtra {
            AppearanceRoot(model: model) {
                MenuBarQuickSpeakView(model: model)
            }
        } label: {
            MenuBarIconLabel(playback: model.store.playbackState)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Applies the chosen appearance from its own view, so only this view (not
/// the whole scene) re-evaluates when the model changes.
private struct AppearanceRoot<Content: View>: View {
    var model: AppModel
    @ViewBuilder let content: Content

    var body: some View {
        content.preferredColorScheme(model.appearance.preferredColorScheme)
    }
}

private struct ExportCommandButton: View {
    var model: AppModel

    var body: some View {
        Button("Export") {
            model.exportSelectedEntry()
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(model.selectedLogEntry == nil)
    }
}

/// The menu-bar icon. It reads only the playback state, so it redraws when
/// that changes rather than on every store change or playback tick, because
/// each update redraws the status item on every display.
private struct MenuBarIconLabel: View {
    let playback: PlaybackState

    var body: some View {
        Image(systemName: Self.systemImage(for: playback.state))
            .accessibilityLabel("AlkiSpeak")
    }

    private static func systemImage(for state: PlaybackSnapshot.State) -> String {
        switch state {
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
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var quickText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AlkiSpeak")
                        .font(WoadieTheme.rounded(size: 16, weight: .semibold))
                    Text(model.readiness.text)
                        .font(WoadieTheme.mono(size: 10, weight: .medium))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                }
                Spacer()
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.store.playbackState.state == .playing ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(model.store.playbackState.bufferedDuration <= 0 && model.store.playbackState.state != .playing)
                .help(model.store.playbackState.state == .playing ? "Pause playback" : "Play cached audio")
            }

            Button {
                model.speakSelectedTextFromMenuBar()
            } label: {
                Label("Speak Selected Text", systemImage: "text.cursor")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(WoadieTheme.borderSubtle))
            .help("Speak the currently selected text from the frontmost app")

            Button {
                model.speakClipboard()
            } label: {
                Label("Speak Clipboard", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(WoadieTheme.borderSubtle))
            .help("Speak the copied text, or the web page a copied link points to")

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

            if model.selectedTextPermissionRequired {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accessibility access is required to read selected text.")
                        .font(WoadieTheme.mono(size: 10, weight: .medium))
                        .foregroundStyle(WoadieTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Open Settings") {
                            model.openAccessibilitySettings()
                        }
                        Button("Try Again") {
                            model.speakSelectedTextFromMenuBar()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            } else if !model.message.isEmpty {
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
    var model: AppModel

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
