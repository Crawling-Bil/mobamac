import Foundation

/// Automatically prunes old session log files (UI spec §9.5) so
/// ~/Library/Logs/MobaMac doesn't grow forever — every SSH/Telnet/Serial
/// session writes its own full byte-for-byte log (see `SessionLogger`), and
/// a heavily-used install can pile up thousands of these over months.
enum LogRetentionManager {
    private static let retentionDaysKey = "MobaMac.logRetentionDays"

    /// How many days a log file is kept before being purged. 0 means
    /// "forever" — never purge. Defaults to 30: long enough that "what did
    /// that device say last week" still works, short enough that the log
    /// folder doesn't quietly eat disk space forever.
    static var retentionDays: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: retentionDaysKey) as? Int
            return stored ?? 30
        }
        set { UserDefaults.standard.set(newValue, forKey: retentionDaysKey) }
    }

    /// Whatever folder logging is pointed at right now — the user's choice
    /// if they made one, the default otherwise. Deliberately only this one
    /// folder: changing the log folder leaves the old one alone rather than
    /// having a retention sweep follow the user around and delete from
    /// somewhere they stopped using.
    static var logDirectory: URL {
        LogSettings.activeDirectory
    }

    /// Deletes every `.log` file whose last modification date is older than
    /// `retentionDays`. Safe to call often — at launch, and again right
    /// after the user changes the setting — since it's just a
    /// modification-date check per file, and a 0 setting (forever) makes it
    /// a no-op. Returns how many files were removed, mainly so callers can
    /// decide whether a "cleaned up N old logs" message is worth showing.
    @discardableResult
    static func purgeExpiredLogs() -> Int {
        guard retentionDays > 0 else { return 0 }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
        let files = (try? FileManager.default.contentsOfDirectory(
            at: logDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        // Only MobaMac's own two extensions, never everything in the
        // folder: the log location is about to become user-settable, and
        // someone may well point it at a folder that has their own files in
        // it.
        var purged = 0
        for url in files where url.pathExtension == "log" || url.pathExtension == "raw" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: url)
                purged += 1
            }
        }
        return purged
    }
}
