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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(profileStore)
                .environmentObject(sessionManager)
                .environmentObject(snippetStore)
                .environmentObject(credentialSetStore)
                .frame(minWidth: 900, minHeight: 560)
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
