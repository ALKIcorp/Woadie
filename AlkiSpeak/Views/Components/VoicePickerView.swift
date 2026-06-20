import SwiftUI

struct VoicePickerView: View {
    @Binding var selection: String
    let selectedLabel: String
    let sections: [VoiceGrouping.Section]
    let favorites: Set<String>
    let onStep: (Int) -> Void
    let onToggleFavorite: (String) -> Void

    var body: some View {
        AlkiDropdown(
            title: selectedLabel,
            sections: dropdownSections,
            selectedID: selection,
            placeholder: "Select Voice",
            onSelect: { selection = $0 },
            onToggleFavorite: onToggleFavorite,
            onStep: onStep
        )
    }

    private var dropdownSections: [AlkiDropdownSection] {
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
