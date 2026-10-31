import AppKit
import SwiftUI

/// A small floating panel near the top-right of the screen that shows what
/// the global speak shortcut did. It never takes focus from the app the user
/// is in, and it hides itself once speech ends.
@MainActor
final class SpeechHUDController {
    private let model: AppModel
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let content = SpeechHUDContent()

    init(model: AppModel) {
        self.model = model
    }

    func show(_ outcome: AppModel.HotKeyOutcome) {
        switch outcome {
        case .speakingSelection, .speakingClipboard, .speakingEditor:
            content.message = outcome == .speakingClipboard ? "Speaking clipboard" : nil
            content.voiceLabel = model.selectedVoiceLabel
            present()
            followPlayback()
        case .stopped:
            flash("Stopped")
        case .nothingSelected:
            flash("Nothing selected")
        case .permissionRequired:
            flash("Allow Accessibility access to read selected text")
        }
    }

    private func flash(_ message: String) {
        content.message = message
        content.voiceLabel = nil
        present()
        scheduleHide(after: .seconds(1.6))
    }

    /// Stays up while the request plays, then fades out shortly after.
    private func followPlayback() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            // Give the request a moment to move the transport off idle.
            try? await Task.sleep(for: .milliseconds(600))
            while let self, !Task.isCancelled {
                switch self.model.store.playbackState.state {
                case .playing, .preparing, .paused:
                    try? await Task.sleep(for: .milliseconds(250))
                case .idle, .stopped, .failed:
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    self.hide()
                    return
                }
            }
        }
    }

    private func scheduleHide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: SpeechHUDView(content: content, model: model) { [weak self] in
            self?.model.stopPlayback()
            self?.hide()
        })
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        panel.setFrame(
            NSRect(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 12, width: size.width, height: size.height),
            display: true
        )
    }
}

@MainActor
@Observable
final class SpeechHUDContent {
    var message: String?
    var voiceLabel: String?
}

private struct SpeechHUDView: View {
    let content: SpeechHUDContent
    let model: AppModel
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: content.voiceLabel == nil ? "info.circle" : "waveform")
                .font(.system(size: 15, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: content.voiceLabel != nil && isSpeaking)
            VStack(alignment: .leading, spacing: 1) {
                if let voice = content.voiceLabel {
                    Text(content.message ?? statusText)
                        .font(.system(size: 12, weight: .semibold))
                    Text(voice)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(content.message ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if content.voiceLabel != nil {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .background(.quaternary, in: Circle())
                .help("Stop speaking")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var isSpeaking: Bool {
        model.store.playbackState.state == .playing
    }

    private var statusText: String {
        switch model.store.playbackState.state {
        case .preparing: return "Preparing…"
        case .paused: return "Paused"
        default: return "Speaking"
        }
    }
}
