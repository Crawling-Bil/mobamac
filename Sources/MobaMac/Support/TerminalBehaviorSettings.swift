import AppKit
import SwiftTerm

/// Two habits carried over from MobaXterm and PuTTY. Both off by default,
/// because both contradict how every other Mac app behaves and finding your
/// clipboard replaced by a stray drag is a nasty surprise if you didn't ask
/// for it.
enum TerminalBehaviorSettings {
    private static let copyOnSelectKey = "MobaMac.copyOnSelect"
    private static let rightClickPastesKey = "MobaMac.rightClickPastes"

    static var copyOnSelect: Bool {
        get { UserDefaults.standard.bool(forKey: copyOnSelectKey) }
        set { UserDefaults.standard.set(newValue, forKey: copyOnSelectKey) }
    }

    static var rightClickPastes: Bool {
        get { UserDefaults.standard.bool(forKey: rightClickPastesKey) }
        set { UserDefaults.standard.set(newValue, forKey: rightClickPastesKey) }
    }
}

/// Shared by the two TerminalView subclasses MobaMac uses — one for
/// SSH/Telnet/Serial, one for the local shell — so the behaviour can't drift
/// between them.
enum TerminalInteraction {
    static func copySelectionIfEnabled(in view: TerminalView) {
        guard TerminalBehaviorSettings.copyOnSelect else { return }
        // Only a real selection. A plain click clears `active`, and emptying
        // the clipboard every time someone clicks to focus the terminal
        // would be worse than not having the feature.
        guard let selection = view.selection, selection.active else { return }
        let text = selection.getSelectedText()
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// True when the click was handled as a paste and the caller should not
    /// fall through to the context menu.
    static func handleRightClickPaste(_ event: NSEvent, in view: TerminalView) -> Bool {
        guard TerminalBehaviorSettings.rightClickPastes else { return false }
        // Control-click still means "context menu", which is the only way
        // back to it once right-click has been taken over.
        guard !event.modifierFlags.contains(.control) else { return false }
        // Deliberately SwiftTerm's own paste, the same one Cmd-V uses, so
        // this goes through the delegate's `send` and therefore through
        // MultiLinePasteGuard. A second paste path that skipped the
        // multi-line confirmation would be most dangerous exactly here: a
        // right-click is fast and easy to do by accident, which is how half
        // a config block ends up in a device.
        view.paste(view)
        return true
    }
}
