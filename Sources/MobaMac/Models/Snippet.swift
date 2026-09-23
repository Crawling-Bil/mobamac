import Foundation

struct Snippet: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var command: String
    /// Optional single-character keyboard shortcut, fired with ⌥⌘ from
    /// anywhere in the app via the "Snippets" menu (see MobaMacApp). Lets a
    /// saved snippet fire without opening the Snippets panel at all.
    /// Optional for the same backward-compat reason as every other field
    /// added after users could already have a snippets.json on disk.
    var shortcutKey: String?
}
