import Foundation

/// Turns the byte stream a session produces into plain text for its log file:
/// what you would have read on screen, with everything a terminal emulator
/// consumes rather than prints taken back out.
///
/// A session log is a document. Network devices color the prompt, redraw the
/// line as you type, and paints progress with carriage returns — all of which
/// belong on screen and none of which belong in something you paste into a
/// report. A byte-for-byte log of "show running-config" from a device with a
/// colored prompt is close to unreadable.
///
/// Stateful on purpose. A single escape sequence routinely straddles two TCP
/// packets, so a regex run over one chunk at a time would let the tail of a
/// split sequence through as literal text. This resumes wherever the previous
/// chunk left off.
///
/// Only the log goes through here. The bytes fed to the terminal view are
/// untouched: color and cursor movement are exactly what should happen there.
final class TerminalOutputSanitizer {
    private enum State {
        case text
        /// Saw ESC; the next byte says what kind of sequence this is.
        case escape
        /// ESC [ — parameters and intermediates, then one final byte.
        case csi
        /// ESC ] / P / X / ^ / _ — runs until BEL or ST. Window titles (OSC)
        /// live here.
        case string
        /// Saw ESC inside a string sequence: ESC \ ends it, anything else
        /// was part of the payload.
        case stringEscape
        /// A two-byte escape such as ESC ( B, whose second byte carries no
        /// terminator of its own.
        case skipOne
    }

    private var state: State = .text
    /// Parameter and intermediate bytes of the CSI sequence being read.
    /// Most sequences are skipped outright, but the handful that move the
    /// cursor along the line, or erase part of it, have to be obeyed or the
    /// log keeps text the screen had already wiped.
    private var csiParameters: [UInt8] = []
    /// A runaway "cursor forward" shouldn't be able to turn one line into
    /// a screenful of padding. Wider than any real terminal, narrow enough
    /// that a malformed sequence does little damage.
    private static let maximumColumn = 512
    /// The line being assembled, as raw UTF-8 bytes. Kept as bytes rather
    /// than Characters so a multi-byte character split across two packets
    /// reassembles on its own.
    private var line: [UInt8] = []
    /// Where the next byte lands. A carriage return rewinds this to 0, which
    /// is how a spinner or a progress bar overwrites itself; only what
    /// survives until the newline reaches the file.
    private var column = 0
    /// A carriage return means nothing until the next byte says what it was
    /// for: CR LF ends a line, CR followed by anything else rewinds and
    /// overwrites. Deciding early would turn every CRLF into a blank line.
    private var pendingCarriageReturn = false

    /// Returns the completed lines this chunk finished, which may be nothing
    /// at all: output is line buffered, so a session sitting at a prompt has
    /// that prompt still held here until `flush()`.
    func filter(_ data: Data) -> Data {
        var out = Data()
        for byte in data {
            switch state {
            case .skipOne:
                state = .text
            case .escape:
                handleEscapeIntroducer(byte)
            case .csi:
                if (0x40...0x7E).contains(byte) {
                    applyCSI(final: byte)
                    csiParameters.removeAll(keepingCapacity: true)
                    state = .text
                } else if csiParameters.count < 32 {
                    csiParameters.append(byte)
                }
            case .string:
                if byte == 0x07 {
                    state = .text
                } else if byte == 0x1B {
                    state = .stringEscape
                }
            case .stringEscape:
                if byte == 0x5C {
                    state = .text
                } else if byte != 0x1B {
                    state = .string
                }
            case .text:
                handleTextByte(byte, into: &out)
            }
        }
        return out
    }

    /// The tail no newline has terminated yet — usually the prompt the
    /// session was sitting at. Written when the log is closed so the last
    /// line isn't lost.
    func flush() -> Data {
        guard !line.isEmpty else { return Data() }
        var out = Data(line)
        out.append(0x0A)
        line.removeAll()
        column = 0
        pendingCarriageReturn = false
        csiParameters.removeAll()
        state = .text
        return out
    }

    /// Obeys the few CSI sequences that change what the finished line says.
    ///
    /// Erase-in-line is the one that matters most: a shell redrawing its
    /// prompt writes carriage return, then ESC [ K to wipe what was there,
    /// then the new text. Ignore the erase and the leftovers of the longer
    /// previous line survive past the end of the new one, so the log grows a
    /// tail of characters that were never on screen.
    private func applyCSI(final: UInt8) {
        // ESC [ ? ... sets terminal modes — bracketed paste and friends.
        // Nothing there moves the cursor.
        if csiParameters.first == 0x3F { return }
        let parameter = firstParameter()

        switch final {
        case 0x4B:                                  // K, erase in line
            switch parameter ?? 0 {
            case 0:
                if column < line.count { line.removeSubrange(column...) }
            case 1:
                for index in 0..<min(column, line.count) { line[index] = 0x20 }
            case 2:
                line.removeAll(keepingCapacity: true)
            default:
                break
            }
        case 0x47, 0x60:                            // G and `, absolute column
            column = min(max(0, (parameter ?? 1) - 1), Self.maximumColumn)
        case 0x43:                                  // C, cursor forward
            column = min(column + max(1, parameter ?? 1), Self.maximumColumn)
        case 0x44:                                  // D, cursor back
            column = max(0, column - max(1, parameter ?? 1))
        default:
            break
        }
    }

    /// The first numeric parameter, or nil when the sequence gave none and
    /// the caller should use that sequence's own default.
    private func firstParameter() -> Int? {
        var value = 0
        var sawDigit = false
        for byte in csiParameters {
            if byte == 0x3B { break }               // ;
            guard (0x30...0x39).contains(byte) else { return sawDigit ? value : nil }
            sawDigit = true
            value = value * 10 + Int(byte - 0x30)
            if value > 9999 { return 9999 }
        }
        return sawDigit ? value : nil
    }

    private func handleEscapeIntroducer(_ byte: UInt8) {
        switch byte {
        case 0x5B:                                  // [
            state = .csi
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F:          // ] P X ^ _
            state = .string
        case 0x28, 0x29, 0x2A, 0x2B, 0x23, 0x25:    // ( ) * + # %
            state = .skipOne
        case 0x1B:
            state = .escape
        default:                                     // ESC 7, ESC =, ESC M ...
            state = .text
        }
    }

    private func handleTextByte(_ byte: UInt8, into out: inout Data) {
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            if byte == 0x0A {
                emitLine(into: &out)
                return
            }
            column = 0
        }

        switch byte {
        case 0x1B:
            state = .escape
        case 0x0A:
            emitLine(into: &out)
        case 0x0D:
            pendingCarriageReturn = true
        case 0x08:
            column = max(0, column - 1)
        case 0x09:
            // Kept: device output uses tabs for column alignment, and
            // dropping them would collapse table output into one run of text.
            place(byte)
        case 0x00...0x1F, 0x7F:
            break
        default:
            place(byte)
        }
    }

    /// Overwrites in place when the cursor was rewound, appends otherwise —
    /// the same thing the screen does. Bytes left over from a longer previous
    /// line stay, because a bare carriage return doesn't erase anything.
    private func place(_ byte: UInt8) {
        // The cursor can be parked past the end of what has been written,
        // after a jump or an erase. Pad, the way the screen would show
        // blanks there.
        if column > line.count {
            line.append(contentsOf: repeatElement(0x20, count: column - line.count))
        }
        if column < line.count {
            line[column] = byte
        } else {
            line.append(byte)
        }
        column += 1
    }

    private func emitLine(into out: inout Data) {
        out.append(contentsOf: line)
        out.append(0x0A)
        line.removeAll(keepingCapacity: true)
        column = 0
    }
}
