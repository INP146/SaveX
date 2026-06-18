import Foundation
import SwiftUI

struct SaveXThemePalette {
    let accent: Color
    let backgroundAccent: Color
    let backgroundAccentSecondary: Color
}

enum SaveXTheme: String, CaseIterable, Identifiable {
    case sapphire
    case violet
    case graphite
    case sunset

    static let defaultTheme: SaveXTheme = .graphite

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .sapphire:
            return "Sapphire"
        case .violet:
            return "Violet"
        case .graphite:
            return "Graphite"
        case .sunset:
            return "Sunset"
        }
    }

    var helpText: String {
        switch self {
        case .sapphire:
            return "Clean blue and indigo without the green cast."
        case .violet:
            return "Expressive purple with a softer pink glow."
        case .graphite:
            return "Neutral slate tones for a quieter interface."
        case .sunset:
            return "Warm coral and orange for a brighter feel."
        }
    }

    var systemImage: String {
        switch self {
        case .sapphire:
            return "sparkle"
        case .violet:
            return "wand.and.stars"
        case .graphite:
            return "circle.lefthalf.filled"
        case .sunset:
            return "sunset.fill"
        }
    }

    var palette: SaveXThemePalette {
        switch self {
        case .sapphire:
            return SaveXThemePalette(
                accent: Color(red: 0.18, green: 0.32, blue: 0.92),
                backgroundAccent: Color(red: 0.16, green: 0.34, blue: 0.95),
                backgroundAccentSecondary: Color(red: 0.48, green: 0.30, blue: 0.95)
            )
        case .violet:
            return SaveXThemePalette(
                accent: Color(red: 0.58, green: 0.22, blue: 0.88),
                backgroundAccent: Color(red: 0.55, green: 0.24, blue: 0.92),
                backgroundAccentSecondary: Color(red: 0.92, green: 0.26, blue: 0.70)
            )
        case .graphite:
            return SaveXThemePalette(
                accent: Color(red: 0.34, green: 0.38, blue: 0.46),
                backgroundAccent: Color(red: 0.36, green: 0.42, blue: 0.52),
                backgroundAccentSecondary: Color(red: 0.18, green: 0.20, blue: 0.26)
            )
        case .sunset:
            return SaveXThemePalette(
                accent: Color(red: 0.92, green: 0.34, blue: 0.24),
                backgroundAccent: Color(red: 0.95, green: 0.40, blue: 0.24),
                backgroundAccentSecondary: Color(red: 0.95, green: 0.68, blue: 0.24)
            )
        }
    }
}

enum SaveXInterfaceStyle: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultStyle: SaveXInterfaceStyle = .system

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .system:
            return "Follow System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var helpText: String {
        switch self {
        case .system:
            return "Match your device appearance."
        case .light:
            return "Always use the light interface."
        case .dark:
            return "Always use the dark interface."
        }
    }

    var systemImage: String {
        switch self {
        case .system:
            return "gearshape"
        case .light:
            return "sun.max.fill"
        case .dark:
            return "moon.fill"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum SaveXThemeSelection: String, CaseIterable, Identifiable {
    case sapphire
    case violet
    case graphite
    case sunset
    case custom

    static let defaultSelection: SaveXThemeSelection = .graphite

    var id: String {
        rawValue
    }

    var presetTheme: SaveXTheme? {
        SaveXTheme(rawValue: rawValue)
    }

    var label: String {
        switch self {
        case .custom:
            return "Custom"
        default:
            return presetTheme?.label ?? SaveXTheme.defaultTheme.label
        }
    }

    var helpText: String {
        switch self {
        case .custom:
            return "Choose your own accent and background colors."
        default:
            return presetTheme?.helpText ?? SaveXTheme.defaultTheme.helpText
        }
    }

    var systemImage: String {
        switch self {
        case .custom:
            return "paintpalette.fill"
        default:
            return presetTheme?.systemImage ?? SaveXTheme.defaultTheme.systemImage
        }
    }
}

struct SaveXResolvedTheme {
    let selection: SaveXThemeSelection
    let palette: SaveXThemePalette

    static let `default` = SaveXResolvedTheme(
        selection: .graphite,
        palette: SaveXTheme.graphite.palette
    )

    static func resolve(
        selectionRaw: String,
        customAccentRaw: String,
        customBackgroundAccentRaw: String,
        customBackgroundAccentSecondaryRaw: String
    ) -> SaveXResolvedTheme {
        let selection = SaveXThemeSelection(rawValue: selectionRaw) ?? .defaultSelection

        if let preset = selection.presetTheme {
            return SaveXResolvedTheme(selection: selection, palette: preset.palette)
        }

        let fallback = SaveXTheme.graphite.palette
        return SaveXResolvedTheme(
            selection: .custom,
            palette: SaveXThemePalette(
                accent: Color(saveXHexRGB: customAccentRaw) ?? fallback.accent,
                backgroundAccent: Color(saveXHexRGB: customBackgroundAccentRaw) ?? fallback.backgroundAccent,
                backgroundAccentSecondary: Color(saveXHexRGB: customBackgroundAccentSecondaryRaw) ?? fallback.backgroundAccentSecondary
            )
        )
    }
}

private struct SaveXThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = SaveXResolvedTheme.default
}

extension EnvironmentValues {
    var saveXTheme: SaveXResolvedTheme {
        get { self[SaveXThemeEnvironmentKey.self] }
        set { self[SaveXThemeEnvironmentKey.self] = newValue }
    }
}

extension Color {
    init?(saveXHexRGB: String) {
        let hex = saveXHexRGB.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("#")

        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }

        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var saveXHexRGBString: String? {
        guard let components = cgColor?.components else { return nil }

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        switch components.count {
        case 2:
            red = components[0]
            green = components[0]
            blue = components[0]
        case 3, 4:
            red = components[0]
            green = components[1]
            blue = components[2]
        default:
            return nil
        }

        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

struct SaveXBackground: View {
    @Environment(\.saveXTheme) private var theme

    var body: some View {
        LinearGradient(
            colors: [
                Color.clear,
                theme.palette.backgroundAccent.opacity(0.16),
                theme.palette.backgroundAccentSecondary.opacity(0.12),
                Color.secondary.opacity(0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .backgroundExtensionEffect()
    }
}

#Preview("Background") {
    SaveXBackground()
}
