import Foundation

/// Writes a per-session log as bytes arrive, independent of whatever
/// scrollback the terminal view keeps on screen. This is what actually
/// solves "output disappears when I scroll" — the file has everything,
/// regardless of what's currently rendered.
///
/// Every session kind arrives here: SSH and SSH-1 through
/// SSHTerminalHostView, Telnet and Serial through RawTerminalHostView, and
/// the local shell through LoggingLocalProcessTerminalView's `dataReceived`
/// override. One `write(_:)` for all five is the reason the sanitizer below
/// only needs to exist in one place.
///
/// What lands in the `.log` is plain text (see `TerminalOutputSanitizer`),
/// not the raw stream: the raw stream is full of color codes and cursor
/// movement and is no use as documentation. `LogSettings.keepRawLogs` keeps
/// the unfiltered bytes too, as a `.raw` file beside it.
final class SessionLogger {
    private let fileHandle: FileHandle?
    private let rawFileHandle: FileHandle?
    private let sanitizer = TerminalOutputSanitizer()
    /// `write(_:)` is called from whichever thread the connection reads on —
    /// a NIO event loop for SSH, a Network.framework queue for Telnet, the
    /// serial port's own queue — and the sanitizer carries state from one
    /// call to the next. Without this, two chunks interleaving would corrupt
    /// a half-parsed escape sequence and put garbage in the file.
    private let lock = NSLock()
    let fileURL: URL
    /// Where the unfiltered bytes go when `LogSettings.keepRawLogs` is on,
    /// nil otherwise.
    let rawFileURL: URL?
    /// Held for the life of the log when the chosen folder came from a
    /// security-scoped bookmark, and released in `close()`.
    private let scopedRoot: URL?

    /// The folder comes from `LogSettings` rather than from the caller.
    /// SessionManager creates loggers in seven places, and threading a path
    /// through all of them only to have each one read the same preference is
    /// a way to end up with one that forgets.
    init(profileName: String, logDirectory: URL? = nil) {
        let base: URL
        if let logDirectory {
            base = logDirectory
            scopedRoot = nil
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } else {
            let resolved = LogSettings.resolveForWriting()
            base = resolved.url
            scopedRoot = resolved.scopedRoot
            // Said once, and cleared as soon as a session gets the folder it
            // asked for, so the warning reflects the present rather than
            // some failure from an hour ago.
            if resolved.didFallBack {
                LogStatus.shared.reportFallback()
            } else {
                LogStatus.shared.clear()
            }
        }

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

        if LogSettings.keepRawLogs {
            let rawURL = url.deletingPathExtension().appendingPathExtension("raw")
            FileManager.default.createFile(atPath: rawURL.path, contents: nil)
            self.rawFileHandle = try? FileHandle(forWritingTo: rawURL)
            self.rawFileURL = rawURL
        } else {
            self.rawFileHandle = nil
            self.rawFileURL = nil
        }
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
    ///
    /// The data handed in is always what the device actually sent, taken
    /// before MobaMac's own highlighting has a chance to inject color codes
    /// of its own — otherwise the sanitizer would be stripping ANSI that
    /// MobaMac had just added, and the log would describe the app rather
    /// than the device.
    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if let rawFileHandle {
            try? rawFileHandle.write(contentsOf: data)
        }
        // Line buffered: a chunk that ends mid-line produces nothing here
        // and is written when its newline arrives, or by `close()`.
        let text = sanitizer.filter(data)
        if !text.isEmpty {
            try? fileHandle?.write(contentsOf: text)
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        // The line the session was sitting on — usually the prompt — has no
        // newline to trigger it, so it is written out here or lost.
        let tail = sanitizer.flush()
        if !tail.isEmpty {
            try? fileHandle?.write(contentsOf: tail)
        }
        try? fileHandle?.close()
        try? rawFileHandle?.close()
        scopedRoot?.stopAccessingSecurityScopedResource()
    }
}
