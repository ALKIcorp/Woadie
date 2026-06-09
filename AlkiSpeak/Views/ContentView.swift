import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(.vertical) {
            AlkiGlassSurface(cornerRadius: 30) {
                VStack(spacing: 12) {
                    WoadieHeaderView(model: model)
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
            }
            .frame(maxWidth: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 900, minHeight: 680)
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

                WoadieWaveformView(
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
                        categories: model.voiceCategories,
                        onStep: model.cycleVoice
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let store = AppStore()
        let dependencies = AppDependencies.live()
        ContentView()
            .environmentObject(AppModel(store: store, dependencies: dependencies))
    }
}
