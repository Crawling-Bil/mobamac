import SwiftUI
import AppKit

/// A plain SPM executable has no Info.plist / .app bundle, so macOS doesn't
/// always give it a foreground activation policy or focus automatically —
/// the SwiftUI window can exist but never actually appear on screen. Forcing
/// both explicitly in applicationDidFinishLaunching is the standard fix.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // UI spec §9.5: sweep old session logs once per launch rather than
        // on a running timer — this app isn't long-lived enough in the
        // background for a timer to matter, and "once at startup" is
        // exactly when a user is least likely to be mid-review of a log
        // that's about to age out.
        LogRetentionManager.purgeExpiredLogs()
    }
}

@main
struct MobaMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var profileStore = ProfileStore()
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var snippetStore = SnippetStore()
    @StateObject private var credentialSetStore = CredentialSetStore()
    @StateObject private var updater = UpdaterController()
    @StateObject private var appearanceSettings = AppearanceSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(profileStore)
                .environmentObject(sessionManager)
                .environmentObject(snippetStore)
                .environmentObject(credentialSetStore)
                .frame(minWidth: 900, minHeight: 560)
                // Light/dark for the app's chrome only. The terminal is
                // painted by TerminalTheme through SwiftTerm and never reads
                // the color scheme, which is the point: a dark terminal in a
                // light app is a normal way to work.
                .preferredColorScheme(appearanceSettings.appearance.colorScheme)
                // UI spec: window defaults — a comfortable first-launch size
                // (bigger than the bare minimum above), and frame autosave
                // (see WindowFrameAutosave) takes over remembering whatever
                // the user resizes it to on every launch after that.
                .background(WindowFrameAutosave())
        }
        .defaultSize(width: 1100, height: 680)
        // Menu-bar shortcuts, unlike a SwiftUI view modifier attached to
        // some on-screen control, keep working no matter which view has
        // focus — including the terminal's own NSView — because AppKit
        // checks menu key equivalents before handing a keystroke to the
        // first responder. That's what makes "press a hotkey, no click
        // needed" actually work for both macros and the command palette.
        .commands {
            // Right under "About MobaMac", which is where macOS apps have
            // put this for twenty years. Sparkle owns everything after the
            // click: the version check, the window showing the release notes
            // from CHANGELOG.md, the download, and the swap-and-relaunch.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)

                Toggle("Automatically Check for Updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                .disabled(!updater.isConfigured)
            }
            // ⌘W used to live on the toolbar's Close Tab button. Now that
            // Close Tab sits inside the Session menu, a Button nested in a
            // SwiftUI Menu isn't instantiated until the menu is opened, so
            // its key equivalent would never be registered. Putting the
            // command in the File menu keeps the shortcut working, makes it
            // discoverable, and — placed after New — takes precedence over
            // the standard Close item that shares ⌘W.
            CommandGroup(after: .newItem) {
                Button("Close Tab") {
                    sessionManager.closeActive()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(sessionManager.activeSession == nil)
            }
            CommandMenu("Macros") {
                if snippetStore.snippets.isEmpty {
                    Text("No snippets saved yet")
                } else {
                    ForEach(snippetStore.snippets) { snippet in
                        Button(snippet.name) {
                            sessionManager.sendToActive(snippet.command + "\n")
                        }
                        .keyboardShortcut(forKey: snippet.shortcutKey)
                        .disabled(sessionManager.activeSession == nil)
                    }
                }
            }
            CommandMenu("Go") {
                Button("Command Palette…") {
                    sessionManager.showingCommandPalette.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            // UI spec: font-size defaults — ⌘+/⌘-/⌘0 zoom, applied live to
            // every open tab at once (SessionManager.applyTerminalFontSize
            // handles per-tab full-screen state) and persisted
            // (TerminalFontSettings) so new tabs — and the next launch —
            // start at whatever size this was last left at.
            CommandMenu("View") {
                Button("Zoom In") {
                    sessionManager.applyTerminalFontSize(TerminalFontSettings.increase())
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    sessionManager.applyTerminalFontSize(TerminalFontSettings.decrease())
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    TerminalFontSettings.reset()
                    sessionManager.applyTerminalFontSize(TerminalFontSettings.pointSize)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        // A `Settings` scene, not a sheet: macOS adds "Settings…" to the app
        // menu with its standard place and shortcut, and keeps one window
        // rather than one per document window.
        Settings {
            PreferencesView()
                .environmentObject(appearanceSettings)
                .environmentObject(updater)
                .preferredColorScheme(appearanceSettings.appearance.colorScheme)
        }
    }
}

private extension View {
    /// Applies ⌥⌘<key> when a snippet has a shortcut set; otherwise leaves
    /// the item shortcut-less (it's still reachable from the Macros menu
    /// by name).
    @ViewBuilder
    func keyboardShortcut(forKey key: String?) -> some View {
        if let key, let char = key.lowercased().first {
            self.keyboardShortcut(KeyEquivalent(char), modifiers: [.command, .option])
        } else {
            self
        }
    }
}
