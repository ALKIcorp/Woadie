import SwiftUI

/// Which custom overlay is showing over the main content.
enum AppOverlay: Identifiable {
    case settings
    case storage

    var id: Int {
        switch self {
        case .settings: return 0
        case .storage: return 1
        }
    }
}

/// Dimmed modal container shared by the settings and storage overlays.
struct OverlayContainer<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            AlkiGlassSurface(cornerRadius: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(title)
                            .font(WoadieTheme.rounded(size: 18, weight: .semibold))
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help("Close")
                    }
                    .padding(20)

                    Divider().opacity(0.4)

                    content
                }
            }
            .frame(maxWidth: 640, maxHeight: 560)
            .padding(40)
        }
        .transition(.opacity)
    }
}

struct SettingsOverlayView: View {
    @ObservedObject var model: AppModel
    var onOpenStorage: () -> Void
    var onClose: () -> Void

    var body: some View {
        OverlayContainer(title: "Settings", onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DisclosureSettingRow(
                        title: "Appearance",
                        systemImage: "circle.lefthalf.filled",
                        subtitle: "Light, dark, or follow the system",
                        initiallyExpanded: true
                    ) {
                        Picker("Appearance", selection: Binding(
                            get: { model.appearance },
                            set: { model.setAppearance($0) }
                        )) {
                            ForEach(AppAppearance.allCases, id: \.self) { appearance in
                                Text(appearance.label).tag(appearance)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    DisclosureSettingRow(
                        title: "Playback Tuning",
                        systemImage: "slider.horizontal.3",
                        subtitle: "Listen-only speed and pitch — clips are never re-rendered",
                        initiallyExpanded: true
                    ) {
                        PlaybackTuningControls(model: model)
                    }

                    DisclosureSettingRow(
                        title: "Storage",
                        systemImage: "internaldrive",
                        subtitle: ByteCountFormatter.string(fromByteCount: model.totalStorageBytes, countStyle: .file) + " across \(model.clipInventory.count) clips"
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                WoadieButton(title: "Open Clips Folder", systemImage: "folder", variant: .default) {
                                    model.openClipsFolder()
                                }
                                WoadieButton(title: "Clean Up Orphans", systemImage: "trash", variant: .default) {
                                    model.cleanupOrphanClips()
                                }
                            }
                            WoadieButton(title: "Open Storage Dashboard", systemImage: "square.grid.2x2", variant: .primary) {
                                onOpenStorage()
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }
}

private struct PlaybackTuningControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            tuningRow(
                label: "Speed",
                value: model.playbackTuning.speed,
                display: String(format: "%.2fx", model.playbackTuning.speed),
                range: PlaybackTuning.speedRange,
                step: 0.05,
                onChange: model.setPlaybackSpeed
            )
            tuningRow(
                label: "Pitch",
                value: model.playbackTuning.pitch,
                display: String(format: "%+.0f st", model.playbackTuning.pitch),
                range: PlaybackTuning.pitchRange,
                step: 1,
                onChange: model.setPlaybackPitch
            )
            Button("Reset to default") { model.resetPlaybackTuning() }
                .buttonStyle(.plain)
                .font(WoadieTheme.mono(size: 10, weight: .semibold))
                .foregroundStyle(WoadieTheme.foregroundSubtle)
                .disabled(model.playbackTuning.isDefault)
        }
    }

    private func tuningRow(
        label: String,
        value: Double,
        display: String,
        range: ClosedRange<Double>,
        step: Double,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(WoadieTheme.rounded(size: 12, weight: .semibold))
                Spacer()
                Text(display)
                    .font(WoadieTheme.mono(size: 11, weight: .medium))
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
            }
            Slider(
                value: Binding(get: { value }, set: { onChange($0) }),
                in: range,
                step: step
            )
        }
    }
}

struct StorageDashboardView: View {
    @ObservedObject var model: AppModel
    var onClose: () -> Void
    @State private var sortField: ClipSortField = .date
    @State private var ascending = false
    @State private var renameTarget: ClipInventoryItem?
    @State private var renameText = ""

    private var items: [ClipInventoryItem] {
        model.sortedClipInventory(by: sortField, ascending: ascending)
    }

    var body: some View {
        OverlayContainer(title: "Storage", onClose: onClose) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Picker("Sort", selection: $sortField) {
                        ForEach(ClipSortField.allCases) { field in
                            Text(field.label).tag(field)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140)

                    Button {
                        ascending.toggle()
                    } label: {
                        Image(systemName: ascending ? "arrow.up" : "arrow.down")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help(ascending ? "Ascending" : "Descending")

                    Spacer()

                    Text(ByteCountFormatter.string(fromByteCount: model.totalStorageBytes, countStyle: .file))
                        .font(WoadieTheme.mono(size: 10, weight: .medium))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                }

                if items.isEmpty {
                    Text("No saved clips yet")
                        .font(WoadieTheme.mono(size: 11, weight: .medium))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(items) { item in
                                row(item)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .sheet(item: $renameTarget) { item in
            renameSheet(item)
        }
    }

    private func row(_ item: ClipInventoryItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(WoadieTheme.rounded(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    label(item.voice)
                    label(String(format: "%.1fs", item.durationSeconds))
                    label(ByteCountFormatter.string(fromByteCount: item.fileSizeBytes, countStyle: .file))
                    label(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Spacer()
            HStack(spacing: 6) {
                IconActionButton(systemImage: "pencil") {
                    renameText = item.displayName
                    renameTarget = item
                }
                IconActionButton(systemImage: "doc.on.doc") {
                    model.copyClipText(item)
                }
                IconActionButton(systemImage: "folder") {
                    model.showClipInFinder(item)
                }
                IconActionButton(systemImage: "trash") {
                    model.deleteClip(item)
                }
            }
        }
        .padding(12)
        .background(WoadieTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WoadieTheme.borderSubtle))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(WoadieTheme.mono(size: 9, weight: .medium))
            .foregroundStyle(WoadieTheme.foregroundSubtle)
    }

    private func renameSheet(_ item: ClipInventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Clip")
                .font(WoadieTheme.rounded(size: 16, weight: .semibold))
            TextField("Display name", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { renameTarget = nil }
                    .buttonStyle(.plain)
                Spacer()
                WoadieButton(title: "Save", variant: .primary) {
                    if let entry = model.store.speechEntries.first(where: { $0.id == item.id }) {
                        model.rename(entry, to: renameText)
                    }
                    renameTarget = nil
                }
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
