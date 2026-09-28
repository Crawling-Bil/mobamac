import Foundation

/// Commands that ask for confirmation before the broadcast bar sends them.
///
/// The bar reaches several devices with one Return, which turns a slip like
/// "reload" into an outage on every one of them. Asking costs one click; not
/// asking can cost a maintenance window. The list is editable in Settings,
/// under Broadcast, because every network has its own dangerous commands.
enum BroadcastSettings {
    private static let patternsKey = "MobaMac.broadcastConfirmPatterns"

    static let defaultPatterns = [
        "reload",
        "write erase",
        "erase startup-config",
        "delete",
        "format",
        "request system restart",
        "commit force",
        "factory-default",
    ]

    /// Stored as the user left it, cleaned of blank lines and duplicates. An
    /// empty list is a choice and is kept; only a list never set falls back
    /// to the defaults.
    static var confirmPatterns: [String] {
        get { UserDefaults.standard.array(forKey: patternsKey) as? [String] ?? defaultPatterns }
        set {
            var seen = Set<String>()
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            UserDefaults.standard.set(cleaned, forKey: patternsKey)
        }
    }

    /// The first pattern found anywhere in `command`, or nil.
    ///
    /// Case is ignored and any run of whitespace counts as one space, so
    /// "Write   Erase" is still caught. A pattern must stand as its own word:
    /// "delete" matches "delete flash:old.bin" but not "undelete". Matching
    /// anywhere rather than only at the start is deliberate, because a
    /// harmless-looking first line of a paste can hide a "reload" further
    /// down. A false alarm costs a click; a miss does not.
    static func matchingPattern(in command: String) -> String? {
        for pattern in confirmPatterns {
            let words = pattern
                .split(whereSeparator: { $0.isWhitespace })
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            let regex = "(?<![A-Za-z0-9_-])" + words.joined(separator: "\\s+") + "(?![A-Za-z0-9_-])"
            if command.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil {
                return pattern
            }
        }
        return nil
    }
}

extension Notification.Name {
    /// Posted by View > Focus Broadcast Input (Control-Command-L). The bar's
    /// text field listens for it, which lets a menu command in the App reach
    /// a field deep in the view tree without a binding threaded through.
    static let focusBroadcastInput = Notification.Name("MobaMac.focusBroadcastInput")
}
