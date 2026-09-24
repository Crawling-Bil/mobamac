import Foundation

/// Sends a session's startup commands once the device is actually ready for
/// them.
///
/// The whole difficulty is "ready". A device accepts the TCP connection and
/// completes the SSH handshake well before its shell is reading input: most
/// network gear is still printing a login banner, and anything typed during
/// that window is discarded with no error and no echo. The command simply
/// never ran, and the first sign of it is paged output twenty minutes later.
///
/// So this waits. By default it waits for the device to stop sending for a
/// short while, which is a good proxy for "the prompt is up and nothing else
/// is coming". A session can instead give a regular expression matching its
/// prompt, for devices where the quiet rule is not enough.
///
/// Commands go out through `ConnectionSession.send`, the same call a real
/// keystroke ends up in. That matters twice over: it is where
/// `KeepaliveGuard.recordInput` lives, so the keepalive's idea of what has
/// been typed stays correct, and it sits below the broadcast fan-out in the
/// terminal view, so a session's startup commands never leak into every
/// other broadcast target. The device echoes them back like anything else,
/// so they appear in the session log without being written there twice.
final class StartupCommandRunner {
    private let commands: [String]
    private let promptPattern: NSRegularExpression?
    private let quietInterval: TimeInterval
    private let lineInterval: TimeInterval
    private weak var connection: ConnectionSession?

    private let lock = NSLock()
    private var lastOutputAt = Date()
    /// A rolling tail of what the device has sent, matched against
    /// `promptPattern`. Capped because a session can print megabytes and
    /// only the last screenful can contain the prompt.
    private var recentOutput = ""
    private var task: Task<Void, Never>?

    /// A device that never stops talking would otherwise never get its
    /// commands. After this long, send them regardless.
    private static let patienceLimit: TimeInterval = 20
    private static let recentOutputLimit = 4096

    init?(profile: SessionProfile, credentialSetCommands: String?, connection: ConnectionSession) {
        let source: String
        let own = profile.startupCommands ?? ""
        if own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = credentialSetCommands ?? ""
        } else {
            source = own
        }

        let lines = source
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        commands = lines
        let pattern = (profile.promptPattern ?? "").trimmingCharacters(in: .whitespaces)
        promptPattern = pattern.isEmpty ? nil : try? NSRegularExpression(pattern: pattern)
        quietInterval = Double(StartupCommandSettings.quietMilliseconds) / 1000
        lineInterval = Double(StartupCommandSettings.lineDelayMilliseconds) / 1000
        self.connection = connection
    }

    /// Fed from the terminal host views, on the same callback that writes the
    /// session log.
    func noteOutput(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        lastOutputAt = Date()
        guard promptPattern != nil else { return }
        recentOutput += String(decoding: data, as: UTF8.self)
        if recentOutput.count > Self.recentOutputLimit {
            recentOutput = String(recentOutput.suffix(Self.recentOutputLimit))
        }
    }

    func start() {
        // The clock starts now, not at the first byte: a device that says
        // nothing at all after connecting still needs its commands.
        lock.lock()
        lastOutputAt = Date()
        recentOutput = ""
        lock.unlock()

        task = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.patienceLimit)
            while !Task.isCancelled, Date() < deadline {
                if self.isReady() { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            await self.sendCommands()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func isReady() -> Bool {
        lock.lock()
        let idle = Date().timeIntervalSince(lastOutputAt)
        let tail = recentOutput
        lock.unlock()

        if let promptPattern {
            let range = NSRange(tail.startIndex..., in: tail)
            return promptPattern.firstMatch(in: tail, range: range) != nil
        }
        return idle >= quietInterval
    }

    private func sendCommands() async {
        for command in commands {
            guard !Task.isCancelled, let connection else { return }
            // Carriage return, which is what Enter puts on the wire, not a
            // newline.
            await connection.send(Data((command + "\r").utf8))
            if lineInterval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(lineInterval * 1_000_000_000))
            }
        }
    }
}
