import Foundation
import SwiftTerm
import AppKit

/// A named terminal color scheme: background/foreground plus the 16 ANSI
/// colors. Stored on SessionProfile as a plain string id (`themeID`) so old
/// saved profiles that predate themes decode fine and just fall back to
/// `.default` — same pattern as `serialPortPath`/`baudRate`.
struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let backgroundHex: String
    let foregroundHex: String
    /// Exactly 16 "#rrggbb" values — the ANSI 0-15 palette.
    let ansiHex: [String]

    static let all: [TerminalTheme] = [.default, .dracula, .solarizedDark, .solarizedLight, .monokai, .nord]

    static func theme(for id: String?) -> TerminalTheme {
        all.first { $0.id == id } ?? .default
    }

    static let `default` = TerminalTheme(
        id: "default",
        name: "Default (Terminal.app)",
        backgroundHex: "#000000",
        foregroundHex: "#e5e5e5",
        ansiHex: [
            "#000000", "#c23621", "#25bc24", "#adad27",
            "#492ee1", "#d338d3", "#33bbc8", "#cbcccd",
            "#818383", "#fc391f", "#31e722", "#eaec23",
            "#5833ff", "#f935f8", "#14f0f0", "#e9ebeb"
        ]
    )

    static let dracula = TerminalTheme(
        id: "dracula",
        name: "Dracula",
        backgroundHex: "#282a36",
        foregroundHex: "#f8f8f2",
        ansiHex: [
            "#21222c", "#ff5555", "#50fa7b", "#f1fa8c",
            "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
            "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
            "#d6acff", "#ff92df", "#a4ffff", "#ffffff"
        ]
    )

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        backgroundHex: "#002b36",
        foregroundHex: "#839496",
        ansiHex: [
            "#073642", "#dc322f", "#859900", "#b58900",
            "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83",
            "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"
        ]
    )

    static let solarizedLight = TerminalTheme(
        id: "solarized-light",
        name: "Solarized Light",
        backgroundHex: "#fdf6e3",
        foregroundHex: "#657b83",
        ansiHex: [
            "#073642", "#dc322f", "#859900", "#b58900",
            "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83",
            "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"
        ]
    )

    static let monokai = TerminalTheme(
        id: "monokai",
        name: "Monokai",
        backgroundHex: "#272822",
        foregroundHex: "#f8f8f2",
        ansiHex: [
            "#272822", "#f92672", "#a6e22e", "#f4bf75",
            "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
            "#75715e", "#f92672", "#a6e22e", "#f4bf75",
            "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5"
        ]
    )

    /// Matches the palette shipped by the Nord project's own terminal-app
    /// configs (nordtheme.com/docs/terminal) — same 16 ANSI values whether
    /// you're looking at iTerm2, Alacritty, or Terminal.app's own Nord
    /// preset, so a session using this theme should look like the same
    /// "native" Nord terminal regardless of which app is showing it.
    static let nord = TerminalTheme(
        id: "nord",
        name: "Nord",
        backgroundHex: "#2e3440",
        foregroundHex: "#d8dee9",
        ansiHex: [
            "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b",
            "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
            "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b",
            "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"
        ]
    )
}

extension TerminalTheme {
    private static let appDefaultIDKey = "MobaMac.appDefaultThemeID"

    /// UI spec: theme defaults — which theme a brand-new session profile
    /// starts on before anyone's explicitly picked one for it. Settable
    /// from the toolbar's live Theme menu ("Set as Default for New
    /// Sessions") rather than a preferences screen this app doesn't have
    /// yet. Deliberately separate from the hardcoded `.default` constant
    /// above, which stays the ultimate fallback if this is ever unset or
    /// points at a theme id that no longer exists.
    static var appDefaultID: String {
        get { UserDefaults.standard.string(forKey: appDefaultIDKey) ?? TerminalTheme.default.id }
        set { UserDefaults.standard.set(newValue, forKey: appDefaultIDKey) }
    }

    static var appDefault: TerminalTheme {
        theme(for: appDefaultID)
    }
}

extension NSColor {
    /// Converts a SwiftTerm.Color (16-bit-per-channel RGB) to a native
    /// NSColor. SwiftTerm has its own `NSColor.make(color:)` for this
    /// internally, but that helper isn't `public`, so this rebuilds it from
    /// the (public) red/green/blue components instead.
    convenience init(swiftTermColor color: SwiftTerm.Color) {
        self.init(
            srgbRed: CGFloat(color.red) / 65535.0,
            green: CGFloat(color.green) / 65535.0,
            blue: CGFloat(color.blue) / 65535.0,
            alpha: 1.0
        )
    }
}

extension TerminalView {
    /// Applies a theme's background/foreground and 16-color ANSI palette.
    /// `Color.parse` and `installColors` are both confirmed-public SwiftTerm
    /// APIs (Colors.swift / AppleTerminalView.swift) — safe to call any time
    /// after the view exists, including more than once.
    func apply(theme: TerminalTheme) {
        if let bg = SwiftTerm.Color.parse(theme.backgroundHex) {
            nativeBackgroundColor = NSColor(swiftTermColor: bg)
        }
        if let fg = SwiftTerm.Color.parse(theme.foregroundHex) {
            nativeForegroundColor = NSColor(swiftTermColor: fg)
        }
        let ansiColors = theme.ansiHex.compactMap { SwiftTerm.Color.parse($0) }
        if ansiColors.count == 16 {
            installColors(ansiColors)
        }
    }

    /// UI spec's chosen terminal font stack: `'Courier New', Consolas,
    /// 'DejaVu Sans Mono', monospace` — a classic dense monospace look,
    /// matching MobaXterm's default rather than the app chrome's font.
    /// That's a CSS font stack, not an AppKit one: only "Courier New" of
    /// those three actually ships with macOS, so it's tried first and
    /// everything else falls back to the system monospaced font (confirmed
    /// public API: `TerminalView.font: NSFont`, Mac/MacTerminalView.swift —
    /// settable, triggers the view's own `resetFont()`).
    ///
    /// Defaults to `TerminalFontSettings.pointSize` — the user's persisted
    /// ⌘+/⌘-/⌘0 zoom level (UI spec: font-size default) — rather than a
    /// fixed 12pt, so a freshly opened tab starts at whatever size the user
    /// last left the app at.
    func applyMobaMacTerminalFont(size: CGFloat = TerminalFontSettings.pointSize) {
        font = NSFont(name: "Courier New", size: size)
            ?? NSFont(name: "Consolas", size: size)
            ?? NSFont(name: "DejaVu Sans Mono", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Bumps the terminal font up while the window is in native macOS full
    /// screen, and restores it on exit. Without this, the windowed-size
    /// default reads as tiny once the window fills an entire display —
    /// going full screen doesn't make the text easier to read, it just
    /// shrinks it relative to your whole field of view (a 27" display in
    /// full screen shows roughly 3x the columns/rows of the app's normal
    /// windowed size at the same point size).
    ///
    /// Reads `TerminalFontSettings.pointSize` fresh from inside each
    /// notification closure (rather than capturing a fixed size up front)
    /// so a ⌘+/⌘- zoom made before ever toggling full screen still applies
    /// correctly the first time the user does.
    ///
    /// Registering the observer needs `window`, which doesn't exist yet at
    /// `makeNSView` time — the view hasn't been inserted into the window's
    /// view hierarchy — so this defers one runloop turn. The closures only
    /// capture `self` weakly, so if the view is torn down (tab closed)
    /// before the window ever changes full-screen state, this leaves a
    /// harmless dangling observer rather than leaking the terminal view.
    func observeFullScreenFontScaling() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.applyMobaMacTerminalFont(size: TerminalFontSettings.pointSize + TerminalFontSettings.fullScreenBump)
            }
            NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.applyMobaMacTerminalFont(size: TerminalFontSettings.pointSize)
            }
        }
    }
}
