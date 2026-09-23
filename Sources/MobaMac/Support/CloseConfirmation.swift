import AppKit

enum CloseConfirmationSettings {
    private static let key = "MobaMac.confirmCloseConnectedSession"

    /// On until someone turns it off. `UserDefaults.bool(forKey:)` can't
    /// express that — it returns false for a key that was never written —
    /// so the object is read and the absence is what means "default".
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// The two "you are about to disconnect something" prompts.
///
/// NSAlert rather than a SwiftUI dialog for one concrete reason: it has a
/// suppression checkbox built in, which is what "Don't ask again" needs, and
/// SwiftUI's `alert` and `confirmationDialog` take buttons and a message and
/// nothing else.
enum CloseConfirmation {
    /// True when the tab should be closed.
    static func confirmCloseTab(sessionName: String, host: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \"\(sessionName)\"?"
        alert.informativeText = "This session is still connected to \(host). "
            + "Closing the tab will disconnect it and close its log file."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        // Cancel is added first, which on macOS puts it at the right-hand
        // end and makes it the default. That is the whole point: Return
        // must not disconnect a live session, and neither must Escape, so
        // the destructive button is explicitly given no key equivalent.
        alert.addButton(withTitle: "Cancel")
        let closeButton = alert.addButton(withTitle: "Close Tab")
        closeButton.hasDestructiveAction = true
        closeButton.keyEquivalent = ""

        let confirmed = alert.runModal() == .alertSecondButtonReturn

        // Only honoured when they actually went through with it. Ticking the
        // box and then cancelling reads as "I changed my mind", and turning
        // the prompt off there would silently disconnect the next session.
        if confirmed, alert.suppressionButton?.state == .on {
            CloseConfirmationSettings.isEnabled = false
        }
        return confirmed
    }

    /// True when the app should quit.
    static func confirmQuit(connectedCount: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit MobaMac?"
        let noun = connectedCount == 1 ? "session is" : "sessions are"
        alert.informativeText = "\(connectedCount) \(noun) still connected. "
            + "Quitting will disconnect them and close their log files."

        alert.addButton(withTitle: "Cancel")
        let quitButton = alert.addButton(withTitle: "Quit")
        quitButton.hasDestructiveAction = true
        quitButton.keyEquivalent = ""

        return alert.runModal() == .alertSecondButtonReturn
    }
}
