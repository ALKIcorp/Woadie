import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var minimumContentHeight: CGFloat = 0
    @State private var activeOverlay: AppOverlay?

    var body: some View {
        GeometryReader { proxy in
            let windowHeight = proxy.size.height

            AlkiGlassSurface(cornerRadius: 16) {
                VStack(spacing: 12) {
                    WoadieHeaderView(
                        model: model,
                        onOpenSettings: { activeOverlay = .settings },
                        onOpenStorage: { activeOverlay = .storage }
                    )
                    topControls

                    HStack(alignment: .top, spacing: 12) {
                        waveformPanel
                        WoadiePlaybackPanel(model: model, onTogglePlayback: model.togglePlayback)
                            .frame(width: 330)
                    }

                    WoadieInputRow(model: model)

                    messageArea

                    if model.isProMode {
                        SpeechLogView(
                            entries: model.chatItems,
                            playingId: model.playingId,
                            selectedId: model.store.selectedLogEntryID,
                            logMode: model.logMode,
                            onLogModeChanged: model.setLogMode,
                            onSelect: model.selectLogEntry,
                            onOpen: model.open,
                            onDelete: model.delete
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(16)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { contentProxy in
                        Color.clear.preference(
                            key: MinimumContentHeightKey.self,
                            value: contentProxy.size.height
                        )
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: max(windowHeight, minimumContentHeight),
                    alignment: .top
                )
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(windowHeight, minimumContentHeight))
        }
        .ignoresSafeArea(.container, edges: .top)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .hidingWindowToolbarTitle()
        .frame(minWidth: 900, minHeight: 680)
        .onPreferenceChange(MinimumContentHeightKey.self) { height in
            guard height > 0, abs(height - minimumContentHeight) > 0.5 else { return }
            minimumContentHeight = height
            guard let window = NSApp.keyWindow else { return }
            window.contentMinSize = NSSize(width: 900, height: height)

            let currentContentSize = window.contentLayoutRect.size
            guard currentContentSize.height > height else { return }

            let topEdge = window.frame.maxY
            let contentRect = NSRect(
                origin: .zero,
                size: NSSize(width: currentContentSize.width, height: height)
            )
            var fittedFrame = window.frameRect(forContentRect: contentRect)
            fittedFrame.origin.x = window.frame.origin.x
            fittedFrame.origin.y = topEdge - fittedFrame.height
            window.setFrame(fittedFrame, display: true, animate: false)
        }
        .tint(WoadieTheme.primary)
        .task {
            while !Task.isCancelled {
                model.refreshResourceStats()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .alert("Port In Use", isPresented: Binding(
            get: { model.showPortInUseAlert },
            set: { model.showPortInUseAlert = $0 }
        )) {
            Button("Switch and Start") {
                model.confirmPortSwitchAndStart()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Port 7777 is already in use. Switch to this engine by stopping the existing service?")
        }
        .overlay {
            overlayContent
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch activeOverlay {
        case .settings:
            SettingsOverlayView(
                model: model,
                onOpenStorage: { activeOverlay = .storage },
                onClose: { activeOverlay = nil }
            )
            .zIndex(10)
        case .storage:
            StorageDashboardView(model: model, onClose: { activeOverlay = nil })
                .zIndex(10)
        case .none:
            EmptyView()
        }
    }

    private var topControls: some View {
        HStack(alignment: .top) {
            Picker("Mode", selection: Binding(
                get: { model.appMode },
                set: { model.setAppMode($0) }
            )) {
                Text("Quick").tag(AppMode.quick)
                Text("Pro").tag(AppMode.pro)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)

            Spacer()

            StatusIndicatorView(model: model)
        }
    }

    private var waveformPanel: some View {
        AlkiGlassSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("NOW SPEAKING")
                            .font(WoadieTheme.mono(size: 9, weight: .semibold))
                            .tracking(1.55)
                            .foregroundStyle(WoadieTheme.foregroundSubtle)
                        Text(model.playback.state == .idle ? "Ready for speech." : "The future sounds clear.")
                            .font(WoadieTheme.rounded(size: 22, weight: .medium))
                    }
                    Spacer()
                    Text(bufferLabel)
                        .font(WoadieTheme.mono(size: 10, weight: .medium))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                }

                VocalSignalView(
                    isActive: model.playback.state == .playing || model.playback.state == .preparing,
                    magnitudes: model.fftMagnitudes
                )
                .frame(maxWidth: .infinity, minHeight: 220)

                HStack {
                    VoicePickerView(
                        selection: Binding(
                            get: { model.selectedVoice },
                            set: { model.selectedVoice = $0 }
                        ),
                        selectedLabel: model.selectedVoiceLabel,
                        sections: model.voiceSections,
                        favorites: model.voiceFavorites,
                        onStep: model.cycleVoice,
                        onToggleFavorite: model.toggleFavorite
                    )
                    Spacer()
                    Text("48 KHZ - MONO - FFT LIVE")
                        .font(WoadieTheme.mono(size: 10, weight: .medium))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                }
            }
            .padding(22)
        }
    }

    private var messageArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.message.isEmpty {
                Label(model.message, systemImage: "info.circle")
                    .foregroundStyle(WoadieTheme.warning)
            }
            if let engineCheckMessage = model.engineCheckMessage {
                Label(engineCheckMessage, systemImage: "engine.combustion")
                    .foregroundStyle(WoadieTheme.warning)
            }
        }
        .font(WoadieTheme.mono(size: 11, weight: .medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(3)
    }

    private var bufferLabel: String {
        let ready = model.store.speechJobs.first?.segments.filter { $0.audioURL != nil }.count ?? 0
        let total = model.store.speechJobs.first?.segments.count ?? 0
        return "BUFFER \(String(format: "%02d", ready)) / \(String(format: "%02d", total))"
    }
}

private struct MinimumContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    @ViewBuilder
    func hidingWindowToolbarTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let store = AppStore()
        let dependencies = AppDependencies.live()
        ContentView()
            .environmentObject(AppModel(store: store, dependencies: dependencies))
    }
}
