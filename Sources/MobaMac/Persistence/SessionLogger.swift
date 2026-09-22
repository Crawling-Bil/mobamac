import Foundation

/// Tees raw session bytes to a per-session log file as they arrive,
/// independent of whatever scrollback the terminal view keeps on screen.
/// This is what actually solves "output disappears when I scroll" —
/// the file has everything, regardless of what's currently rendered.
///
/// For SSH sessions, SSHTerminalHostView calls `write(_:)` itself as bytes
/// come in from Citadel. For the local-terminal tab, we don't write through
/// here at all — see LocalTerminalHostView, which lets the `script` command
/// do the capture at the OS/PTY level instead (SwiftTerm's local-process
/// delegate doesn't expose a clean public hook for this — see
/// migueldeicaza/SwiftTerm#308). Either way, `fileURL` is the path the log
/// ends up at.
final class SessionLogger {
    private let fileHandle: FileHandle?
    let fileURL: URL

    init(profileName: String, logDirectory: URL? = nil) {
        let base = logDirectory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MobaMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // `createFile` truncates an existing file, so two logs opened in the
        // same second (a quick Try Again, say) would otherwise wipe the first.
        let fileName = Self.fileName(for: profileName, at: Date())
        var url = base.appendingPathComponent(fileName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = base.appendingPathComponent(String(fileName.dropLast(4)) + "-\(suffix).log")
            suffix += 1
        }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.fileHandle = try? FileHandle(forWritingTo: url)
        self.fileURL = url
    }

    /// `2026-09-22_14-30-15_sw-ntt-dist01.log`
    ///
    /// Timestamp first, so a plain name sort in Finder or `ls` is also a
    /// chronological sort. The session name is reduced to letters, digits,
    /// `.`, `-` and `_`: Quick Connect names look like "10.25.2.1:22", and a
    /// colon shows up in Finder as a slash, while spaces and quotes make the
    /// path awkward to use from a shell. `init` adds a `-2`, `-3`... suffix
    /// when a log for the same session already exists for that second.
    static func fileName(for profileName: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: date)

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let folded = profileName.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var name = String(folded.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" })
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        if name.isEmpty { name = "session" }
        if name.count > 80 { name = String(name.prefix(80)) }

        return "\(stamp)_\(name).log"
    }

    /// `FileHandle.write(_:)` reports failure by raising an Objective-C
    /// exception, which Swift can't catch: a full disk, or a write that
    /// lands after `close()`, would take the whole app down. The throwing
    /// `write(contentsOf:)` turns both into an ignorable error. Losing a
    /// log line is better than losing every open session.
    func write(_ data: Data) {
        try? fileHandle?.write(contentsOf: data)
    }

    func close() {
        try? fileHandle?.close()
    }
}
