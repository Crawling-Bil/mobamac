import Foundation

/// User-facing settings for session logging.
enum LogSettings {
    private static let keepRawLogsKey = "MobaMac.keepRawSessionLogs"

    /// Also keep the unfiltered byte stream beside each `.log`, as `.raw`.
    ///
    /// Off by default: the whole point of the filter is that the log reads
    /// like a document. But when something on screen looks wrong — a prompt
    /// that redraws oddly, output that wraps where it shouldn't — the escape
    /// sequences are the evidence, and by then the session is over.
    static var keepRawLogs: Bool {
        get { UserDefaults.standard.bool(forKey: keepRawLogsKey) }
        set { UserDefaults.standard.set(newValue, forKey: keepRawLogsKey) }
    }
}
