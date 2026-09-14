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

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let safeName = profileName.replacingOccurrences(of: "/", with: "_")
        let filename = "\(safeName)_\(formatter.string(from: Date())).log"
        let url = base.appendingPathComponent(filename)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.fileHandle = try? FileHandle(forWritingTo: url)
        self.fileURL = url
    }

    func write(_ data: Data) {
        fileHandle?.write(data)
    }

    func close() {
        try? fileHandle?.close()
    }
}
