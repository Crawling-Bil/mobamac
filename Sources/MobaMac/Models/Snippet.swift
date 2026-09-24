import Foundation

/// The device types a snippet can be limited to. Matched against the
/// device-type folder a session sits in, so "show int status" can stay off
/// the button bar while a firewall tab is in front.
enum SnippetDeviceType: String, CaseIterable, Identifiable, Codable, Hashable {
    case firewall = "Firewall"
    case aSwitch = "Switch"
    case router = "Router"
    case wlc = "WLC"

    var id: String { rawValue }
}

struct Snippet: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var command: String
    /// Optional single-character keyboard shortcut, fired with ⌥⌘ from
    /// anywhere in the app via the "Snippets" menu (see MobaMacApp). Lets a
    /// saved snippet run without opening the Snippets panel at all.
    /// Optional for the same backward-compat reason as every other field
    /// added after users could already have a snippets.json on disk.
    var shortcutKey: String?
    /// Shown as a button above the terminal, for the handful of commands run
    /// dozens of times a day. Everything is still managed from the Snippets
    /// panel: a second place to save commands would only raise the question
    /// of which one to use.
    var showInButtonBar: Bool?
    /// Position in the button bar. Nil sorts last.
    var buttonBarOrder: Int?
    /// Limits the button to sessions in these device-type folders. Empty or
    /// nil shows it everywhere.
    var deviceTypes: [SnippetDeviceType]?
    /// Asks before running. For "reload", "write erase", "commit force":
    /// commands where a misplaced click is expensive.
    var confirmBeforeRunning: Bool?

    var isInButtonBar: Bool { showInButtonBar == true }

    func appliesTo(deviceType: String?) -> Bool {
        guard let deviceTypes, !deviceTypes.isEmpty else { return true }
        guard let deviceType else { return false }
        return deviceTypes.contains { $0.rawValue.caseInsensitiveCompare(deviceType) == .orderedSame }
    }
}
