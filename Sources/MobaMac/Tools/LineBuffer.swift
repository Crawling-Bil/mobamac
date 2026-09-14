import Foundation

/// Buffers bytes into complete lines before highlighting. Only route
/// through this when the per-session toggle (`OpenSession.highlightingEnabled`)
/// is ON — otherwise feed SwiftTerm directly, unbuffered, as the app already
/// does for every session that hasn't opted in.
final class LineBuffer {
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []

        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            let lineData = pending[..<newlineIndex]
            pending.removeSubrange(...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(TerminalHighlighter.highlightLine(line))
            }
        }
        return lines
    }
}
