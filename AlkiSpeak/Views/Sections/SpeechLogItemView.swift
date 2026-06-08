import SwiftUI
import AppKit

struct SpeechLogItemView: View {
    let entry: SpeechEntry
    let isPlaying: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false
    @State private var copied = false
    @State private var confirmOpen = false
    @State private var confirmDelete = false
    @State private var showStats = false

    var body: some View {
        ZStack(alignment: .leading) {
            if isPlaying {
                Rectangle()
                    .fill(WoadieTheme.primary)
                    .frame(width: 2)
                    .cornerRadius(1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(entry.textContent)
                    .font(WoadieTheme.rounded(size: 13, weight: .regular))
                    .foregroundStyle(WoadieTheme.foreground)
                    .lineSpacing(3)
                    .lineLimit(2)
                    .padding(.trailing, 60)

                HStack(spacing: 8) {
                    Text(entry.voice)
                        .font(WoadieTheme.mono(size: 9, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(WoadieTheme.primary.opacity(0.14))
                        .clipShape(Capsule())
                    Text(WoadieTheme.timeFormatter.string(from: entry.createdAt))
                        .font(WoadieTheme.mono(size: 10, weight: .medium))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                        .textCase(.uppercase)
                        .tracking(1.2)
                }
            }
            .padding(14)
            .frame(width: 260, alignment: .leading)
        }
        .background(isSelected ? Color.primary.opacity(0.08) : Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected || isPlaying ? Color.primary.opacity(0.32) : WoadieTheme.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                IconActionButton(systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copyToClipboard()
                }
                IconActionButton(systemImage: "chart.bar.doc.horizontal") {
                    showStats = true
                }
                IconActionButton(systemImage: "arrow.down.left.and.arrow.up.right") {
                    confirmOpen = true
                }
            }
            .opacity(isHovered ? 1 : 0)
            .padding(10)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Open") { confirmOpen = true }
            Button("Stats") { showStats = true }
            Button("Delete", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Opening this will replace what's currently in your workspace. Continue?", isPresented: $confirmOpen) {
            Button("Yes") { onOpen() }
            Button("No", role: .cancel) {}
        }
        .confirmationDialog("Delete this entry? The audio files will be permanently removed from your device.", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showStats) {
            SpeechStatsView(entry: entry)
        }
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.textContent, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}

private struct SpeechStatsView: View {
    let entry: SpeechEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stats ID Card")
                .font(WoadieTheme.mono(size: 14, weight: .bold))
            stat("Tokens used", entry.stats.tokenCount.map(String.init) ?? "-")
            stat("Generation time", String(format: "%.2f s", entry.stats.generationTimeSeconds))
            stat("Audio file size", ByteCountFormatter.string(fromByteCount: entry.stats.fileSizeBytes, countStyle: .file))
            stat("CPU delta", String(format: "%.1f%%", entry.stats.resourceAfter.cpuPercent - entry.stats.resourceBefore.cpuPercent))
            stat("RAM delta", String(format: "%.1f MB", entry.stats.resourceAfter.ramUsedMB - entry.stats.resourceBefore.ramUsedMB))
            stat("Character count", "\(entry.stats.characterCount)")
            stat("Segment count", "\(entry.stats.segmentCount)")
            stat("Voice", entry.voice)
            stat("Model", entry.model)
            stat("Timestamp", entry.createdAt.formatted(date: .abbreviated, time: .standard))
        }
        .padding(24)
        .frame(width: 360)
        .background(WoadieTheme.background)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(WoadieTheme.foregroundSubtle)
            Spacer()
            Text(value)
                .foregroundStyle(WoadieTheme.foreground)
        }
        .font(WoadieTheme.mono(size: 11, weight: .medium))
    }
}
