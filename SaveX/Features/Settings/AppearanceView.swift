import SwiftUI

struct AppearanceView: View {
    @AppStorage(SaveXStorageKey.theme) private var themeRaw = SaveXThemeSelection.defaultSelection.rawValue
    @AppStorage(SaveXStorageKey.interfaceStyle) private var interfaceStyleRaw = SaveXInterfaceStyle.defaultStyle.rawValue
    @AppStorage(SaveXStorageKey.customThemeAccent) private var customAccentRaw = ""
    @AppStorage(SaveXStorageKey.customThemeBackgroundAccent) private var customBackgroundAccentRaw = ""
    @AppStorage(SaveXStorageKey.customThemeBackgroundAccentSecondary) private var customBackgroundAccentSecondaryRaw = ""

    private var selectedTheme: SaveXThemeSelection {
        SaveXThemeSelection(rawValue: themeRaw) ?? .defaultSelection
    }

    private var resolvedTheme: SaveXResolvedTheme {
        SaveXResolvedTheme.resolve(
            selectionRaw: themeRaw,
            customAccentRaw: customAccentRaw,
            customBackgroundAccentRaw: customBackgroundAccentRaw,
            customBackgroundAccentSecondaryRaw: customBackgroundAccentSecondaryRaw
        )
    }

    private var themeBinding: Binding<SaveXThemeSelection> {
        Binding(
            get: { selectedTheme },
            set: { themeRaw = $0.rawValue }
        )
    }

    private var selectedInterfaceStyle: SaveXInterfaceStyle {
        SaveXInterfaceStyle(rawValue: interfaceStyleRaw) ?? .defaultStyle
    }

    private var interfaceStyleBinding: Binding<SaveXInterfaceStyle> {
        Binding(
            get: { selectedInterfaceStyle },
            set: { interfaceStyleRaw = $0.rawValue }
        )
    }

    var body: some View {
        ZStack {
            SaveXBackground()

            StablePageScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    interfaceStylePanel
                    presetPanel
                    customPanel
                }
                .padding(.top, 12)
            }
        }
        .saveXNavigationChrome()
        .navigationTitle("Appearance")
    }

    private var interfaceStylePanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: selectedInterfaceStyle.systemImage)
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Interface Style")
                            .font(.subheadline.weight(.semibold))
                        Text(selectedInterfaceStyle.helpText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Interface Style", selection: interfaceStyleBinding) {
                    ForEach(SaveXInterfaceStyle.allCases) { style in
                        Text(style.label)
                            .tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var presetPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Presets")
                    .font(.subheadline.weight(.semibold))

                VStack(spacing: 0) {
                    ForEach(SaveXTheme.allCases) { theme in
                        Button {
                            themeRaw = theme.rawValue
                        } label: {
                            presetRow(for: theme)
                        }
                        .buttonStyle(.plain)

                        if theme.id != SaveXTheme.allCases.last?.id {
                            Divider()
                                .opacity(0.45)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.05))
                )
            }
        }
    }

    private var customPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Custom colors")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if selectedTheme == .custom {
                        StatusPill("Active", systemImage: "checkmark.circle.fill")
                    }
                }

                Text("Pick an accent color and two soft background colors for your own theme.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if selectedTheme == .custom {
                    VStack(spacing: 12) {
                        ColorPicker("Accent", selection: customAccentBinding, supportsOpacity: false)
                        ColorPicker("Background accent", selection: customBackgroundAccentBinding, supportsOpacity: false)
                        ColorPicker("Secondary background accent", selection: customBackgroundAccentSecondaryBinding, supportsOpacity: false)
                    }

                    Button {
                        resetCustomColors()
                    } label: {
                        Label("Reset Custom Colors", systemImage: "arrow.counterclockwise")
                            .saveXGlassLabel(expands: true)
                    }
                    .buttonStyle(.glass)
                } else {
                    Button {
                        themeRaw = SaveXThemeSelection.custom.rawValue
                    } label: {
                        Label("Use Custom Colors", systemImage: "paintpalette.fill")
                            .saveXGlassLabel(expands: true)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
    }

    private func presetRow(for theme: SaveXTheme) -> some View {
        HStack(spacing: 12) {
            paletteSwatch(theme.palette)

            VStack(alignment: .leading, spacing: 2) {
                Text(theme.label)
                    .font(.subheadline.weight(.semibold))
                Text(theme.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if selectedTheme.rawValue == theme.rawValue {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.palette.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func paletteSwatch(_ palette: SaveXThemePalette) -> some View {
        HStack(spacing: 0) {
            palette.accent
            palette.backgroundAccent
            palette.backgroundAccentSecondary
        }
        .frame(width: 42, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        )
    }

    private var customAccentBinding: Binding<Color> {
        customColorBinding(
            rawValue: $customAccentRaw,
            fallback: SaveXTheme.graphite.palette.accent
        )
    }

    private var customBackgroundAccentBinding: Binding<Color> {
        customColorBinding(
            rawValue: $customBackgroundAccentRaw,
            fallback: SaveXTheme.graphite.palette.backgroundAccent
        )
    }

    private var customBackgroundAccentSecondaryBinding: Binding<Color> {
        customColorBinding(
            rawValue: $customBackgroundAccentSecondaryRaw,
            fallback: SaveXTheme.graphite.palette.backgroundAccentSecondary
        )
    }

    private func customColorBinding(rawValue: Binding<String>, fallback: Color) -> Binding<Color> {
        Binding(
            get: { Color(saveXHexRGB: rawValue.wrappedValue) ?? fallback },
            set: { newValue in
                if let hex = newValue.saveXHexRGBString {
                    rawValue.wrappedValue = hex
                }
            }
        )
    }

    private func resetCustomColors() {
        customAccentRaw = SaveXTheme.graphite.palette.accent.saveXHexRGBString ?? "#576175"
        customBackgroundAccentRaw = SaveXTheme.graphite.palette.backgroundAccent.saveXHexRGBString ?? "#5C6B85"
        customBackgroundAccentSecondaryRaw = SaveXTheme.graphite.palette.backgroundAccentSecondary.saveXHexRGBString ?? "#2E3342"
    }
}

#Preview("Appearance") {
    NavigationStack {
        AppearanceView()
    }
}
