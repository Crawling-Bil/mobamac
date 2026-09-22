import Foundation

/// Decides when the idle keepalive, a bare newline typed into the session,
/// is safe to send.
///
/// A newline is indistinguishable from the user pressing Enter, and network
/// gear confirms destructive commands with Enter: Cisco's
/// "Proceed with reload? [confirm]", "write erase", "delete flash:...".
/// Sending one blindly after 30 idle seconds could reload a switch while
/// its user was away from the desk. So a keepalive only goes out when all
/// of these hold:
///
/// - Nothing has been sent *or received* for the idle interval. Output
///   counts: a long `show tech` scrolling by is not idle.
/// - The user has no half-typed command on the line. Enter would run it.
/// - The last line from the device looks like an ordinary prompt
///   (see `isSafePrompt`), and not like any confirmation or login prompt.
///
/// Every check fails closed: when in doubt, no keepalive, and the worst
/// case is the device's own idle timeout logging the session out.
///
/// The state is touched from the output loop, from `send`, and from the
/// keepalive task, so it sits behind a lock.
final class KeepaliveGuard {
    private let lock = NSLock()
    private var lastInputAt: Date
    private var lastOutputAt: Date
    private var outputTail: [Unicode.Scalar] = []
    private var hasUnsubmittedInput = false

    /// Enough to hold the last line even behind a burst of escape codes.
    private static let tailLimit = 2048

    init(now: Date = Date()) {
        lastInputAt = now
        lastOutputAt = now
    }

    func recordOutput(_ data: Data, now: Date = Date()) {
        let scalars = String(decoding: data, as: UTF8.self).unicodeScalars
        lock.lock()
        defer { lock.unlock() }
        lastOutputAt = now
        outputTail.append(contentsOf: scalars)
        if outputTail.count > Self.tailLimit {
            outputTail.removeFirst(outputTail.count - Self.tailLimit)
        }
    }

    /// Anything the user types or pastes. Enter, Ctrl-C and Ctrl-U leave an
    /// empty line; every other byte (letters, Tab completion, arrow keys
    /// recalling history) may leave a command sitting on it.
    func recordInput(_ data: Data, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        lastInputAt = now
        for byte in data {
            switch byte {
            case 0x0D, 0x0A, 0x03, 0x15:
                hasUnsubmittedInput = false
            default:
                hasUnsubmittedInput = true
            }
        }
    }

    func recordKeepaliveSent(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        lastInputAt = now
    }

    func shouldSendKeepalive(idleThreshold: TimeInterval, now: Date = Date()) -> Bool {
        lock.lock()
        let lastActivity = max(lastInputAt, lastOutputAt)
        let pending = hasUnsubmittedInput
        let tail = outputTail
        lock.unlock()

        guard now.timeIntervalSince(lastActivity) >= idleThreshold else { return false }
        guard !pending else { return false }
        return Self.isSafePrompt(Self.lastLine(of: tail))
    }

    // MARK: - Prompt classification

    /// Lowercased. A line containing any of these is waiting for an answer,
    /// not a command.
    private static let confirmationMarkers = [
        "[confirm]", "[yes/no]", "(yes/no)", "[y/n]", "(y/n)", "(y or n)",
        "--more--", "press any key",
    ]

    /// True only for a line that looks like a normal CLI prompt:
    ///
    /// - ends in `#`, `>`, `$` or `%` (Cisco, Huawei `<sysname>`, FortiOS,
    ///   PAN-OS, Junos, Linux shells), or
    /// - ends in `]` *and* is a single bracketed word such as Huawei's
    ///   `[sysname]` or `[~HUAWEI-GigabitEthernet0/0/1]`. Checking the last
    ///   character alone would let "Proceed with reload? [confirm]" through,
    ///   which is exactly the case this exists to stop.
    ///
    /// Always false for a line ending in `:` (Password:, Username:, [Y/N]:),
    /// for any line containing `?` (prompts never do, questions always do),
    /// and for anything too long to be a prompt.
    static func isSafePrompt(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return false }

        let lower = trimmed.lowercased()
        if confirmationMarkers.contains(where: { lower.contains($0) }) { return false }
        if trimmed.contains("?") { return false }

        guard let last = trimmed.last else { return false }
        switch last {
        case "#", ">", "$", "%":
            return true
        case "]":
            let bracketedWord = trimmed.hasPrefix("[") || trimmed.hasPrefix("<")
            return bracketedWord && !trimmed.contains(where: { $0.isWhitespace })
        default:
            return false
        }
    }

    /// The last line of terminal output as it would read on screen: escape
    /// sequences removed (colour codes, window titles), only what follows
    /// the last line feed, only what follows the last carriage return that
    /// has anything after it, and backspaces applied so "reload" typed and
    /// then erased doesn't count as still being there.
    ///
    /// Works on Unicode scalars on purpose. In Swift "\r\n" is a single
    /// Character, so splitting a String on "\n" would not find it.
    static func lastLine(of scalars: [Unicode.Scalar]) -> String {
        var visible: [Unicode.Scalar] = []
        visible.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x1B {
                index += 1
                guard index < scalars.count else { break }
                let kind = scalars[index].value
                index += 1
                if kind == 0x5B {
                    // CSI: parameters/intermediates, then one final byte 0x40-0x7E.
                    while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) {
                        index += 1
                    }
                    index += 1
                } else if kind == 0x5D {
                    // OSC: runs to BEL or to ESC-backslash.
                    while index < scalars.count {
                        let value = scalars[index].value
                        if value == 0x07 { index += 1; break }
                        if value == 0x1B, index + 1 < scalars.count, scalars[index + 1].value == 0x5C {
                            index += 2
                            break
                        }
                        index += 1
                    }
                }
                // Any other ESC x pair: both scalars already skipped.
                continue
            }
            if scalar.value != 0x00 {
                visible.append(scalar)
            }
            index += 1
        }

        let afterLineFeed: ArraySlice<Unicode.Scalar>
        if let lineFeed = visible.lastIndex(where: { $0.value == 0x0A }) {
            afterLineFeed = visible[(lineFeed + 1)...]
        } else {
            afterLineFeed = visible[...]
        }

        let segments = afterLineFeed.split(separator: "\r", omittingEmptySubsequences: false)
        let line = segments.last(where: { segment in
            segment.contains { !CharacterSet.whitespaces.contains($0) }
        }) ?? []

        var result: [Unicode.Scalar] = []
        for scalar in line {
            if scalar.value == 0x08 || scalar.value == 0x7F {
                if !result.isEmpty { result.removeLast() }
            } else {
                result.append(scalar)
            }
        }

        var view = String.UnicodeScalarView()
        view.append(contentsOf: result)
        return String(view)
    }
}
