import Foundation

/// Validates what goes into a session profile's Host/Port fields before it's
/// allowed to be saved. Previously `NewSessionSheet` only checked
/// `!host.isEmpty`, so literally any string — including a bare number like
/// "12345" that isn't even a well-formed IPv4 address — could be saved as a
/// session that would then just hang or fail to connect with no explanation.
enum HostValidator {
    /// Strict dotted-quad IPv4 check: exactly 4 octets, each 0-255, no
    /// leading-zero weirdness (so "01" is rejected, "0" is fine).
    static func isValidIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for octet in octets {
            guard let n = Int(octet), n >= 0, n <= 255, String(n) == octet else { return false }
        }
        return true
    }

    /// RFC 1123-ish hostname: dot-separated labels of letters/digits/hyphens,
    /// each 1-63 chars, never starting/ending with a hyphen, whole name <=253
    /// chars. A label made up of only digits is rejected here too — that's
    /// what catches a stray "12345" typed into the Host field instead of
    /// silently letting it become a session that can never actually connect.
    static func isValidHostname(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard (1...63).contains(label.count) else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            guard label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
            if label.allSatisfy({ $0.isNumber }) { return false }
        }
        return true
    }

    /// A host is acceptable if it's either a valid IPv4 address or a valid
    /// hostname — not just "non-empty".
    static func isValidHost(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return isValidIPv4(trimmed) || isValidHostname(trimmed)
    }

    static func isValidPort(_ value: String) -> Bool {
        guard let n = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return (1...65535).contains(n)
    }

    /// Human-readable reason a host string was rejected, for inline field errors.
    static func hostErrorMessage(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil } // don't nag before the user has typed anything
        if isValidHost(trimmed) { return nil }
        return "Enter a valid IPv4 address (e.g. 192.168.1.10) or hostname (e.g. server.local)."
    }

    static func portErrorMessage(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isValidPort(trimmed) { return nil }
        return "Port must be a number between 1 and 65535."
    }
}
