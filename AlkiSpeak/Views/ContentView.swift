import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var minimumContentHeight: CGFloat = 0
    @State private var activeOverlay: AppOverlay?
    @State private var isDropTargeted = false

    var body: some View {
        GeometryReader { proxy in
            let windowHeight = proxy.size.height

            AlkiGlassSurface(cornerRadius: 16) {
                ScrollView(.vertical) {
                    VStack(spacing: 12) {
                        WoadieHeaderView(
                            model: model,
                            onOpenSettings: { activeOverlay = .settings },
                            onOpenStorage: { activeOverlay = .storage },
                            onOpenVoices: { activeOverlay = .voices(.mine) }
                        )
                        topControls

                        HStack(alignment: .top, spacing: 12) {
                            NowSpeakingPanel(model: model, onNewVoice: { activeOverlay = .voices(.new) })
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
                                onReinsert: model.reinsert,
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
                }
                .scrollIndicators(.hidden)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .frame(maxWidth: .infinity)
            .frame(height: windowHeight)
        }
        .ignoresSafeArea(.container, edges: .top)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .hidingWindowToolbarTitle()
        .frame(minWidth: 900, minHeight: 680)
        .onPreferenceChange(MinimumContentHeightKey.self) { height in
            guard height > 0, abs(height - minimumContentHeight) > 0.5 else { return }
            minimumContentHeight = height
            let mainWindow = NSApp.windows.first { $0.styleMask.contains(.titled) }
            guard let window = mainWindow ?? NSApp.keyWindow else { return }

            let currentContentSize = window.contentLayoutRect.size
            let topEdge = window.frame.maxY
            let contentRect = NSRect(
                origin: .zero,
                size: NSSize(width: currentContentSize.width, height: ceil(height))
            )
            var fittedFrame = window.frameRect(forContentRect: contentRect)
            // Never ask for more than the screen holds; past that the content scrolls.
            if let screenFrame = window.screen?.visibleFrame {
                fittedFrame.size.height = min(fittedFrame.height, screenFrame.height)
            }
            // The measured content height shifts by a few points with the
            // window's own height (892.5 at 896 tall, 895.5 at 893), so fitting
            // it exactly made the two chase each other at 80% CPU for up to a
            // minute after launch. Grow whenever the content needs more room;
            // shrink only for a real change.
            let grows = fittedFrame.height > window.frame.height + 0.5
            let shrinks = fittedFrame.height < window.frame.height - 4
            guard grows || shrinks else { return }

            window.contentMinSize = NSSize(
                width: 900,
                height: window.contentRect(forFrameRect: fittedFrame).height
            )
            fittedFrame.origin.x = window.frame.origin.x
            fittedFrame.origin.y = topEdge - fittedFrame.height
            window.setFrame(fittedFrame, display: true, animate: false)
        }
        .tint(WoadieTheme.primary)
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
        .environment(\.openVoices, OpenVoicesAction { activeOverlay = .voices($0) })
        // Drop a document or a link anywhere on the window to read it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            if url.isFileURL {
                model.importDocument(at: url)
            } else if DocumentImporter.webURL(in: url.absoluteString) != nil {
                model.importWebPage(url)
            } else {
                return false
            }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(WoadieTheme.primary.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .overlay(
                        Label("Drop to read it aloud", systemImage: "doc.text")
                            .font(WoadieTheme.rounded(size: 15, weight: .semibold))
                            .padding(14)
                            .background(.ultraThinMaterial, in: Capsule())
                    )
                    .padding(6)
                    .allowsHitTesting(false)
            }
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
        case .voices(let tab):
            VoicesOverlayView(model: model, tab: tab, onClose: { activeOverlay = nil })
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
            // Natural width, so the "Mode" label never wraps when the
            // segments size themselves evenly.
            .fixedSize()

            Spacer()

            StatusIndicatorView(model: model)
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
}

/// Its own view so playback ticks, which it reads for the waveform, re-render
/// this panel and not the whole window.
private struct NowSpeakingPanel: View {
    static let readAlongHeight: CGFloat = 100

    var model: AppModel
    var onNewVoice: () -> Void

    var body: some View {
        let readAlong = model.readAlongState
        AlkiGlassSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("NOW SPEAKING")
                            .font(WoadieTheme.mono(size: 9, weight: .semibold))
                            .tracking(1.55)
                            .foregroundStyle(WoadieTheme.foregroundSubtle)
                        if let readAlong {
                            ReadAlongText(state: readAlong) { offset in
                                model.seekReadAlong(segmentIndex: readAlong.segmentIndex, offset: offset)
                            }
                            .frame(maxWidth: .infinity, minHeight: Self.readAlongHeight, maxHeight: Self.readAlongHeight, alignment: .topLeading)
                        } else {
                            Text(model.playback.state == .idle ? "Ready for speech." : "The future sounds clear.")
                                .font(WoadieTheme.rounded(size: 22, weight: .medium))
                        }
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
                // The waveform gives up the room the read-along text takes,
                // so the panel (and window) keep their height.
                .frame(maxWidth: .infinity, minHeight: readAlong == nil ? 220 : 220 - (Self.readAlongHeight - 28))

                HStack {
                    VoicePickerView(
                        selection: Binding(
                            get: { model.selectedVoice },
                            set: { model.selectedVoice = $0 }
                        ),
                        selectedLabel: model.selectedVoiceLabel,
                        sections: model.voiceDropdownSections,
                        onStep: model.cycleVoice,
                        onToggleFavorite: model.toggleFavorite,
                        onPreview: model.previewVoice,
                        onNewVoice: onNewVoice
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

    private var bufferLabel: String {
        let ready = model.store.speechJobs.first?.segments.filter { $0.audioURL != nil }.count ?? 0
        let total = model.store.speechJobs.first?.segments.count ?? 0
        return "BUFFER \(String(format: "%02d", ready)) / \(String(format: "%02d", total))"
    }
}

/// The passage being spoken with the current word or sentence highlighted.
/// Each word is a link that seeks there when the clip can seek.
private struct ReadAlongText: View {
    let state: AppModel.ReadAlongState
    let onSeek: (Int) -> Void

    var body: some View {
        Text(attributed)
            .font(WoadieTheme.rounded(size: 16, weight: .medium))
            .lineSpacing(4)
            .tint(WoadieTheme.foreground)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "alkiseek", let offset = Int(url.host() ?? "") else { return .systemAction }
                onSeek(offset)
                return .handled
            })
            .animation(.easeOut(duration: 0.15), value: state.highlight)
            .help(state.canSeek ? "Click a word to jump there" : "")
    }

    private var attributed: AttributedString {
        let text = state.passage as NSString
        var result = AttributedString()
        // Words as separate runs so each can be highlighted and clicked.
        var pieces: [(range: NSRange, isWord: Bool)] = []
        var cursor = 0
        for word in state.words.isEmpty ? [NSRange(location: 0, length: text.length)] : state.words {
            if word.location > cursor { pieces.append((NSRange(location: cursor, length: word.location - cursor), false)) }
            pieces.append((word, true))
            cursor = word.location + word.length
        }
        if cursor < text.length { pieces.append((NSRange(location: cursor, length: text.length - cursor), false)) }

        for piece in pieces {
            var run = AttributedString(text.substring(with: piece.range))
            let isHighlighted = state.highlight.map { NSIntersectionRange($0, piece.range).length > 0 } ?? false
            run.foregroundColor = isHighlighted ? WoadieTheme.foreground : WoadieTheme.foregroundMuted
            if isHighlighted {
                // The scrubber's accent, so the two read as one control.
                run.backgroundColor = Color.accentColor.opacity(0.3)
            }
            if state.canSeek, piece.isWord {
                run.link = URL(string: "alkiseek://\(state.passageOffset + piece.range.location)")
            }
            result.append(run)
        }
        return result
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
            .environment(AppModel(store: store, dependencies: dependencies))
    }
}
