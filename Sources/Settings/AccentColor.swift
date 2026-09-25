import AppKit
import SwiftUI

/// The user-selected colour for positive usage and active work indicators.
///
/// Raw values are persistence keys, not display copy. Keeping them stable lets
/// labels and ordering change without losing an existing choice.
enum AccentColorChoice: String, CaseIterable, Identifiable {
    case system
    case pink = "ff33e1"
    case red = "eb4236"
    case orange = "eb8436"
    case yellow = "ffd400"
    case green = "00ff88"
    case teal = "00e5cc"
    case blue = "36a8eb"
    case indigo = "6c5ce7"
    case purple = "b026ff"
    case offWhite = "f7f6f5"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:   return L10n.t("Device accent color")
        case .pink:     return L10n.t("Pink")
        case .red:      return L10n.t("Red")
        case .orange:   return L10n.t("Orange")
        case .yellow:   return L10n.t("Yellow")
        case .green:    return L10n.t("Green")
        case .teal:     return L10n.t("Teal")
        case .blue:     return L10n.t("Blue")
        case .indigo:   return L10n.t("Indigo")
        case .purple:   return L10n.t("Purple")
        case .offWhite: return L10n.t("Off-white")
        }
    }

    var color: Color {
        switch self {
        case .system:   return Color(nsColor: .controlAccentColor)
        case .pink:     return Color(hex: 0xFF33E1)
        case .red:      return Color(hex: 0xEB4236)
        case .orange:   return Color(hex: 0xEB8436)
        case .yellow:   return Color(hex: 0xFFD400)
        case .green:    return Palette.ample
        case .teal:     return Color(hex: 0x00E5CC)
        case .blue:     return Color(hex: 0x36A8EB)
        case .indigo:   return Color(hex: 0x6C5CE7)
        case .purple:   return Color(hex: 0xB026FF)
        case .offWhite: return Color(hex: 0xF7F6F5)
        }
    }
}

private struct PenguinNotchAccentColorKey: EnvironmentKey {
    static let defaultValue = Color(nsColor: .controlAccentColor)
}

extension EnvironmentValues {
    var penguinnotchAccentColor: Color {
        get { self[PenguinNotchAccentColorKey.self] }
        set { self[PenguinNotchAccentColorKey.self] = newValue }
    }
}
