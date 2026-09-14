import Foundation

/// Injects ANSI color codes into decoded terminal output before it reaches
/// SwiftTerm's feed() — highlights IPs, MAC addresses, up/down status, and
/// vendor error patterns so they're easy to scan.
///
/// IMPORTANT TRADE-OFF: this requires buffering until a full line arrives,
/// which delays ALL output — including the user's own typed-character echo
/// — until Enter is pressed. Do not wire this in as an always-on default;
/// gate it behind a per-session toggle (see `OpenSession.highlightingEnabled`)
/// so it only costs latency when the user actually wants it.
enum TerminalHighlighter {
    private static let ipv4Regex = try! NSRegularExpression(
        pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
    )
    private static let macDottedRegex = try! NSRegularExpression(
        pattern: #"\b[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}\b"#
    )
    private static let macColonRegex = try! NSRegularExpression(
        pattern: #"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b"#
    )
    private static let statusUpRegex = try! NSRegularExpression(
        pattern: #"\b(up|active|enabled)\b"#, options: [.caseInsensitive]
    )
    private static let statusDownRegex = try! NSRegularExpression(
        pattern: #"\b(down|inactive|disabled)\b"#, options: [.caseInsensitive]
    )

    /// Fixed substrings, not regex. Cisco and Palo Alto are high-confidence
    /// (well-documented, stable across versions). Fortinet and Huawei are
    /// starting points — verify against real device output and correct as
    /// needed, firmware versions vary more on these two.
    private static let errorPhrases: [String] = [
        "% Invalid input detected", "% Incomplete command", "% Ambiguous command", "% Unrecognized command",
        "Invalid syntax", "Unknown command", "Unknown command module",
        "Command fail", "entry not found", "value parse error", "unknown action",
        "% Invalid input",
        "Error: Unrecognized command found", "Error: Wrong parameter found", "Error: Too many parameters found"
    ]

    static func highlightLine(_ line: String) -> String {
        guard !line.contains("\u{1B}[") else { return line }

        for phrase in errorPhrases where line.contains(phrase) {
            return "\u{1B}[1;31m\(line)\u{1B}[0m"
        }

        var result = line
        result = colorize(result, regex: ipv4Regex, ansiCode: "34")
        result = colorize(result, regex: macDottedRegex, ansiCode: "36")
        result = colorize(result, regex: macColonRegex, ansiCode: "36")
        result = colorize(result, regex: statusUpRegex, ansiCode: "32")
        result = colorize(result, regex: statusDownRegex, ansiCode: "31")
        return result
    }

    private static func colorize(_ text: String, regex: NSRegularExpression, ansiCode: String) -> String {
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var mutable = nsText
        for match in matches.reversed() {
            let matched = mutable.substring(with: match.range)
            let wrapped = "\u{1B}[\(ansiCode)m\(matched)\u{1B}[0m"
            mutable = mutable.replacingCharacters(in: match.range, with: wrapped) as NSString
        }
        return mutable as String
    }
}
