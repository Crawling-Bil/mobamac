import AppKit
import SwiftTerm

/// Two optional mouse behaviours familiar from other terminal clients.
/// Both off by default,
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

    /// The text a Service would act on, or nil when there is nothing worth
    /// sending.
    ///
    /// The content is checked, not just the `active` flag. A selection can be
    /// active and still hold nothing a Service can use: dragging past the
    /// last prompt or triple-clicking an empty row gives back newlines and
    /// spaces. Handing a Service that fails the same way as handing it an
    /// empty string, with "There was a problem with the input to the
    /// Service", so both count as no selection.
    ///
    /// When there is real text it goes across exactly as selected, trailing
    /// whitespace included: in device output the spacing is often part of
    /// what was meant to be copied.
    static func selectedTextForServices(in view: TerminalView) -> String? {
        guard let selection = view.selection, selection.active else { return nil }
        let text = selection.getSelectedText()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Answers the question macOS puts to the first responder when it builds
    /// the Services menu: can you supply text for this?
    ///
    /// NSTextView answers it for free, which is why Services work everywhere
    /// else. SwiftTerm never implements it at all, so every Service that
    /// takes text stays dimmed over a terminal selection no matter how much
    /// is highlighted.
    ///
    /// nil means "not me", and that is what keeps those items correctly
    /// dimmed when nothing is selected. Only the sending direction is
    /// offered: a Service that writes text back would be typing it straight
    /// into whatever device is on the other end of the session.
    static func servicesRequestor(
        sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?,
        in view: TerminalView
    ) -> Any? {
        guard sendType == .string, returnType == nil else { return nil }
        return selectedTextForServices(in: view) == nil ? nil : view
    }

    /// Hands the selection to the Service on the pasteboard macOS supplied.
    ///
    /// Deliberately not the general pasteboard: using a Service would
    /// otherwise overwrite whatever the user had copied, as a side effect
    /// they never asked for.
    static func writeSelection(to pasteboard: NSPasteboard, in view: TerminalView) -> Bool {
        guard let text = selectedTextForServices(in: view) else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
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
