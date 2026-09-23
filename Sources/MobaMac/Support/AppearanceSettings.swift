import SwiftUI

/// Light or dark for the app's own chrome: sidebar, toolbar, tab bar, status
/// bar, panels and sheets.
///
/// Separate from `TerminalTheme`, and deliberately so. A dark terminal inside
/// a light app is a normal way to work — the terminal is a document, not part
/// of the window furniture — so switching the app to Light must leave the
/// terminal exactly as it was.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil means "follow macOS", which is what `preferredColorScheme`
    /// already takes to mean "don't override".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

final class AppearanceSettings: ObservableObject {
    private static let key = "MobaMac.appAppearance"

    @Published var appearance: AppAppearance {
        didSet {
            guard appearance != oldValue else { return }
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.key)
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.key) ?? ""
        appearance = AppAppearance(rawValue: stored) ?? .system
    }
}
