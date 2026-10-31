import SwiftUI

struct VoicePickerView: View {
    @Binding var selection: String
    let selectedLabel: String
    /// Built once per voice list change; see `AppStore.voiceDropdownSections`.
    let sections: [AlkiDropdownSection]
    let onStep: (Int) -> Void
    let onToggleFavorite: (String) -> Void

    var body: some View {
        AlkiDropdown(
            title: selectedLabel,
            sections: sections,
            selectedID: selection,
            placeholder: "Select Voice",
            onSelect: { selection = $0 },
            onToggleFavorite: onToggleFavorite,
            onStep: onStep
        )
    }

    static func dropdownSections(_ sections: [VoiceGrouping.Section], favorites: Set<String>) -> [AlkiDropdownSection] {
        sections.map { section in
            AlkiDropdownSection(
                id: section.id,
                title: section.title,
                options: section.voices.map { voice in
                    AlkiDropdownOption(
                        id: voice.id,
                        label: voice.label,
                        detail: voice.source.isSynthesisSupported ? nil : "Coming soon",
                        isFavorite: favorites.contains(voice.id),
                        isEnabled: voice.isAvailable && voice.source.isSynthesisSupported
                    )
                }
            )
        }
    }
}
