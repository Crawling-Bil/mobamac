import AppKit

/// Warns before forwarding a multi-line paste to a remote/console session
/// (UI spec §9.3): pasting several lines into an SSH/Telnet/Serial session
/// sends each line as if typed with Enter pressed after every one — if the
/// clipboard held something other than a deliberate sequence of commands (a
/// config block copied from docs, a password with a stray newline, a whole
/// script), that's an easy way to fire off several unintended commands in a
/// row before you can hit Ctrl-C. Local Terminal is deliberately not routed
/// through this — it's the user's own shell on their own machine, which is
/// the normal, expected place to paste multi-line text.
enum MultiLinePasteGuard {
    private static let suppressKey = "MobaMac.suppressMultiLinePasteWarning"

    /// True once the user has checked "Don't ask again" in the warning
    /// dialog. Stored in UserDefaults so the choice survives relaunches —
    /// this is a one-way opt-out; there's no UI to turn it back on short of
    /// clearing app defaults, matching how most apps treat this kind of
    /// prompt.
    static var isSuppressed: Bool {
        get { UserDefaults.standard.bool(forKey: suppressKey) }
        set { UserDefaults.standard.set(newValue, forKey: suppressKey) }
    }

    /// Counts how many distinct lines of content `data` decodes to, treating
    /// \r\n/\r/\n interchangeably and ignoring a single trailing line break
    /// (so one Enter keystroke — a lone "\r" — reads as 1 line, never 2).
    /// A single keystroke or a single-line paste always comes back 1 here;
    /// only a batch containing an embedded line break reads higher, which is
    /// exactly what distinguishes "several lines pasted at once" from
    /// ordinary typing — each keystroke, Enter included, always arrives as
    /// its own separate `send` call, never bundled with others.
    static func lineCount(in data: Data) -> Int {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return 1 }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return max(lines.count, 1)
    }

    /// Shows a blocking confirmation alert if `data` looks like a multi-line
    /// paste and the user hasn't opted out, and returns whether the data
    /// should still be sent. Safe to call from any `TerminalViewDelegate`'s
    /// `send` — those are AppKit input-event callbacks that already run on
    /// the main thread, and `NSAlert.runModal()` blocking there is the same
    /// thing any other "are you sure?" dialog does elsewhere in AppKit.
    static func shouldSend(_ data: Data) -> Bool {
        guard !isSuppressed else { return true }
        let count = lineCount(in: data)
        guard count >= 2 else { return true }

        let alert = NSAlert()
        alert.messageText = "Paste \(count) lines?"
        alert.informativeText = "Each line will be sent to this session as if typed, with Enter pressed after every one. If this isn't meant to run as a series of commands, cancel and check what's on your clipboard first."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            isSuppressed = true
        }
        return response == .alertFirstButtonReturn
    }
}
