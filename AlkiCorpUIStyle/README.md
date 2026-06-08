# Alki Corp. UI Style Framework

This directory contains the core design language and reusable SwiftUI components for the **Alki Corp.** ecosystem, extracted from the "The Grid" project.

## 🎨 Design Language

The Alki Corp. aesthetic is characterized by:
- **Glassmorphism**: Heavy use of `.ultraThinMaterial` and custom glass effects.
- **Ambient Atmosphere**: Dynamic, blurred background glow clusters.
- **Cyber-Modern Themes**: A selection of high-contrast, tech-inspired color palettes (Onyx, Ghost, Acid, etc.).
- **Rounded Geometry**: Consistent use of continuous-style rounded rectangles (typical corner radius: 18, 22, 28).

## 📁 Structure

- **`Sources/Theme.swift`**: The core color engine. Includes `ThemePalette`, the `AlkiThemes` collection, and the `AlkiBackgroundView`.
- **`Sources/GlassBase.swift`**: Foundational glass components including `GlassCard`, `GlassMenu`, and the reusable `GlassSurface`.
- **`Sources/SharedComponents.swift`**: Interactive elements like `AlkiActionButtonStyle`, `AlkiSecondaryButtonStyle`, `AlkiMetricCell`, and `AlkiTagPill`.

## 🚀 How to Use

### 1. Set up the Background
Wrap your main view in a `ZStack` and place the `AlkiBackgroundView` at the bottom.

```swift
ZStack {
    AlkiBackgroundView(displayTheme: AlkiThemes[0], isDarkMode: true)
    
    VStack {
        Text("Welcome to The Grid")
            .font(.system(size: 34, weight: .light, design: .rounded))
    }
}
```

### 2. Use Glass Containers
Use `GlassSurface` to wrap your panels and widgets.

```swift
GlassSurface(accent: theme.accent, isDarkMode: true) {
    VStack {
        Text("System Status")
        AlkiTagPill(title: "CONNECTED", accent: .green, isDarkMode: true)
    }
}
```

### 3. Apply Button Styles
Apply the custom button styles to any SwiftUI `Button`.

```swift
Button("Execute Scan") {
    // Action
}
.buttonStyle(AlkiActionButtonStyle(accent: theme.accent, isDarkMode: true))
```

### 4. Display Metrics
Use `AlkiMetricCell` for consistent data visualization.

```swift
AlkiMetricCell(
    title: "UPTIME",
    value: "99.9%",
    detail: "LAST 24 HOURS",
    accent: theme.accent,
    isDarkMode: true
)
```

## 🛠 Maintenance

This folder is intended to be a standalone reference for porting the design language to new projects. When making changes, ensure that you maintain the "continuous" corner styles and the specific opacity values (e.g., `0.18`, `0.12`, `0.08`) defined in the source files to keep the look consistent.
