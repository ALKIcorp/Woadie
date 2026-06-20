import SwiftUI

// MARK: - Dropdown / disclosure primitives

/// A single selectable option inside an `AlkiDropdown`.
struct AlkiDropdownOption: Identifiable, Hashable {
    let id: String
    let label: String
    var detail: String?
    var isFavorite: Bool
    var isEnabled: Bool

    init(id: String, label: String, detail: String? = nil, isFavorite: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.label = label
        self.detail = detail
        self.isFavorite = isFavorite
        self.isEnabled = isEnabled
    }
}

/// A titled group of options.
struct AlkiDropdownSection: Identifiable, Hashable {
    let id: String
    let title: String
    let options: [AlkiDropdownOption]
}

/// Reusable disclosure dropdown shared by the voice picker and other surfaces.
/// Renders a capsule trigger that reveals sectioned options in a popover, with
/// optional favorite toggles per option.
struct AlkiDropdown: View {
    let title: String
    let sections: [AlkiDropdownSection]
    let selectedID: String
    var placeholder: String = "Select"
    var onSelect: (String) -> Void
    var onToggleFavorite: ((String) -> Void)?
    var onStep: ((Int) -> Void)?

    @State private var isPresented = false
    @State private var expandedSectionIDs: Set<String> = []

    init(
        title: String,
        sections: [AlkiDropdownSection],
        selectedID: String,
        placeholder: String = "Select",
        onSelect: @escaping (String) -> Void,
        onToggleFavorite: ((String) -> Void)? = nil,
        onStep: ((Int) -> Void)? = nil
    ) {
        self.title = title
        self.sections = sections
        self.selectedID = selectedID
        self.placeholder = placeholder
        self.onSelect = onSelect
        self.onToggleFavorite = onToggleFavorite
        self.onStep = onStep
    }

    var body: some View {
        HStack(spacing: 10) {
            if let onStep {
                Button { onStep(-1) } label: {
                    Image(systemName: "chevron.up").frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }

            Button {
                isPresented.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text((title.isEmpty ? placeholder : title).uppercased())
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.18), value: title)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                optionList
            }
            .onChange(of: isPresented) { _, presented in
                guard presented else { return }
                if let activeSection = sections.first(where: { section in
                    section.options.contains { $0.id == selectedID }
                }) {
                    expandedSectionIDs = [activeSection.id]
                }
            }

            if let onStep {
                Button { onStep(1) } label: {
                    Image(systemName: "chevron.down").frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .font(WoadieTheme.rounded(size: 11, weight: .semibold))
        .background(Color.white.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(WoadieTheme.borderSubtle))
        .frame(maxWidth: 320)
    }

    private var optionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sections) { section in
                    sectionDisclosure(section)
                }
            }
            .padding(16)
        }
        .frame(width: 320, height: 360)
    }

    private func sectionDisclosure(_ section: AlkiDropdownSection) -> some View {
        let isExpanded = expandedSectionIDs.contains(section.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if isExpanded {
                    expandedSectionIDs.remove(section.id)
                } else {
                    expandedSectionIDs.insert(section.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                    Text(section.title.uppercased())
                        .font(WoadieTheme.mono(size: 9, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                    Spacer(minLength: 4)
                    Text("\(section.options.count)")
                        .font(WoadieTheme.mono(size: 9, weight: .regular))
                        .foregroundStyle(WoadieTheme.foregroundSubtle.opacity(0.6))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(section.options) { option in
                        optionRow(option)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    private func optionRow(_ option: AlkiDropdownOption) -> some View {
        HStack(spacing: 8) {
            Button {
                guard option.isEnabled else { return }
                onSelect(option.id)
                isPresented = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: option.id == selectedID ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(option.id == selectedID ? WoadieTheme.primary : WoadieTheme.foregroundSubtle)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label)
                            .font(WoadieTheme.rounded(size: 12, weight: .medium))
                        if let detail = option.detail {
                            Text(detail)
                                .font(WoadieTheme.mono(size: 9, weight: .regular))
                                .foregroundStyle(WoadieTheme.foregroundSubtle)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!option.isEnabled)
            .opacity(option.isEnabled ? 1 : 0.45)

            if let onToggleFavorite {
                Button { onToggleFavorite(option.id) } label: {
                    Image(systemName: option.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(option.isFavorite ? WoadieTheme.warning : WoadieTheme.foregroundSubtle)
                }
                .buttonStyle(.plain)
                .help(option.isFavorite ? "Remove from favorites" : "Add to favorites")
            }
        }
        .padding(.vertical, 3)
    }
}

/// A settings row that discloses extra content below a title/subtitle header.
struct DisclosureSettingRow<Content: View>: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    @State private var expanded: Bool
    @ViewBuilder var content: Content

    init(
        title: String,
        systemImage: String,
        subtitle: String? = nil,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        _expanded = State(initialValue: initiallyExpanded)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .frame(width: 20)
                        .foregroundStyle(WoadieTheme.foregroundMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(WoadieTheme.rounded(size: 13, weight: .semibold))
                        if let subtitle {
                            Text(subtitle)
                                .font(WoadieTheme.mono(size: 10, weight: .regular))
                                .foregroundStyle(WoadieTheme.foregroundSubtle)
                        }
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(WoadieTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(WoadieTheme.borderSubtle))
    }
}

/// Plain glyph-only transport button (no chrome), used for playback controls.
struct TransportButton: View {
    let systemImage: String
    var size: CGFloat = 21
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Reusable live vocal signal (FFT waveform) view.
struct VocalSignalView: View {
    let isActive: Bool
    let magnitudes: [Float]

    var body: some View {
        WoadieWaveformView(isActive: isActive, magnitudes: magnitudes)
    }
}
