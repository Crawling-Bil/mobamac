import Foundation
import NIO
import NIOFoundationCompat
import NIOSSH
import Crypto
import Citadel

/// Bridges an interactive SSH shell (via Citadel's withPTY) to a
/// ConnectionSession the UI layer can feed into a SwiftTerm.TerminalView.
///
/// Host key verification is TOFU (trust-on-first-use), backed by
/// `KnownHostsStore` — see `HostKeyValidator` below. First connection to a
/// host is trusted and remembered; if the key ever changes afterward the
/// connection is rejected with `SessionError.hostKeyMismatch` unless the
/// user explicitly retries via `retryTrustingNewHostKey()`.
@available(macOS 15.0, *)
final class SSHConnectionSession: ConnectionSession {
    var onOutput: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let profile: SessionProfile
    private let secret: String?
    private var client: SSHClient?
    private var ptyTask: Task<Void, Never>?

    /// Set once withPTY hands us its stdin writer, so `send`/`resize` can use
    /// it after the closure that created it has returned control to us.
    private var stdinWriter: TTYStdinWriter?

    /// UI spec §9.1 — network gear's idle `exec-timeout` (commonly 5–10
    /// minutes) drops a session that's just sitting there while someone
    /// reads a doc. `lastActivityAt` tracks the last real keystroke sent
    /// down this channel; `keepaliveTask` watches it and, once it's been
    /// idle for the configured interval, sends a single newline to keep the
    /// device from timing us out. Confirmed there's no clean Citadel-level
    /// SSH global-request keepalive hook exposed by the resolved package
    /// version, so this is the spec's explicit application-level fallback
    /// instead — crude, but it works against every vendor's CLI and is
    /// harmless at a shell prompt (worst case: an extra blank prompt line).
    private var keepaliveTask: Task<Void, Never>?
    private var lastActivityAt = Date()

    init(profile: SessionProfile, secret: String?) {
        self.profile = profile
        self.secret = secret
    }

    func start() async throws {
        try await connect(trustNewHostKey: false)
    }

    /// Re-attempts the connection after the user has explicitly chosen to
    /// trust a host key that changed since the last successful connection —
    /// the recovery path for `SessionError.hostKeyMismatch`, surfaced as a
    /// "Trust New Key & Reconnect" button in ContentView. Same idea as
    /// deleting a stale line from `~/.ssh/known_hosts` and reconnecting.
    func retryTrustingNewHostKey() async throws {
        try await connect(trustNewHostKey: true)
    }

    private func connect(trustNewHostKey: Bool) async throws {
        let authMethod: SSHAuthenticationMethod
        switch profile.authMethod {
        case .password:
            authMethod = .passwordBased(username: profile.username, password: secret ?? "")
        case .privateKey:
            guard let keyPath = profile.privateKeyPath, !keyPath.isEmpty else {
                throw SessionError.missingPrivateKeyPath
            }
            authMethod = try privateKeyAuthMethod(username: profile.username, keyPath: keyPath, passphrase: secret)
        case .agent:
            throw SessionError.agentAuthNotYetImplemented
        }

        let settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { authMethod },
            hostKeyValidator: .custom(
                HostKeyValidator(host: profile.host, port: profile.port, trustOverride: trustNewHostKey)
            )
        )

        let client = try await SSHClient.connect(to: settings)
        self.client = client

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([.ECHO: 1])
        )

        ptyTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.withPTY(request) { ttyOutput, ttyStdinWriter in
                    self.stdinWriter = ttyStdinWriter
                    self.lastActivityAt = Date()
                    self.startKeepaliveIfNeeded()
                    for try await chunk in ttyOutput {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            self.onOutput?(Data(buffer: buffer))
                        }
                    }
                }
                self.keepaliveTask?.cancel()
                self.onClose?(nil)
            } catch {
                self.keepaliveTask?.cancel()
                self.onClose?(error)
            }
        }
    }

    /// Loads a private key file and returns the matching Citadel auth method.
    /// Only OpenSSH-format keys are parseable at all (Citadel's own
    /// detector requires the "-----BEGIN OPENSSH PRIVATE KEY-----" header),
    /// and only RSA/Ed25519 have a constructor Citadel exposes — ECDSA keys
    /// are detected but not yet loadable. Encrypted keys *are* supported by
    /// the resolved Citadel version here (AES-CTR + bcrypt KDF, same as
    /// OpenSSH itself), so a passphrase in the session's secret field is
    /// tried as the decryption key when one is set.
    private func privateKeyAuthMethod(username: String, keyPath: String, passphrase: String?) throws -> SSHAuthenticationMethod {
        let expandedPath = (keyPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SessionError.privateKeyNotFound(path: expandedPath)
        }
        guard let keyString = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            throw SessionError.privateKeyFormatUnsupported(reason: "couldn't read the file as text.")
        }

        let keyType: SSHKeyType
        do {
            keyType = try SSHKeyDetection.detectPrivateKeyType(from: keyString)
        } catch SSHKeyDetectionError.invalidPrivateKeyFormat {
            throw SessionError.privateKeyFormatUnsupported(
                reason: "only OpenSSH-format keys are supported (the file should start with \"-----BEGIN OPENSSH PRIVATE KEY-----\"). Convert an older PEM-style key with `ssh-keygen -p -f <path>`."
            )
        } catch {
            throw SessionError.privateKeyFormatUnsupported(reason: error.localizedDescription)
        }

        let hasPassphrase = !(passphrase ?? "").isEmpty
        let decryptionKey = hasPassphrase ? passphrase?.data(using: .utf8) : nil

        do {
            switch keyType {
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: keyString, decryptionKey: decryptionKey)
                return .rsa(username: username, privateKey: key)
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: keyString, decryptionKey: decryptionKey)
                return .ed25519(username: username, privateKey: key)
            default:
                throw SessionError.privateKeyFormatUnsupported(
                    reason: "\(keyType.description) keys aren't supported yet — only RSA and Ed25519 OpenSSH keys are."
                )
            }
        } catch let error as SessionError {
            throw error
        } catch {
            throw SessionError.privateKeyLoadFailed(passphraseProvided: hasPassphrase)
        }
    }

    func send(_ data: Data) async {
        lastActivityAt = Date()
        guard let stdinWriter else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        try? await stdinWriter.write(buffer)
    }

    func resize(cols: Int, rows: Int) async {
        guard let stdinWriter else { return }
        try? await stdinWriter.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    func close() async {
        keepaliveTask?.cancel()
        ptyTask?.cancel()
        try? await client?.close()
    }

    /// Starts the idle-keepalive watcher (UI spec §9.1). `nil` on the
    /// profile means "use the default" (30s); `0` is the explicit off
    /// switch some hardened environments need (they log keepalives as
    /// real activity, which defeats the point of an idle timeout audit).
    private func startKeepaliveIfNeeded() {
        let interval = profile.keepaliveInterval ?? 30
        guard interval > 0 else { return }
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                let idleSeconds = Date().timeIntervalSince(self.lastActivityAt)
                if idleSeconds >= Double(interval) {
                    await self.sendKeepaliveNewline()
                }
            }
        }
    }

    /// The actual keepalive "ping": a bare newline on the PTY's stdin. Not
    /// pretty — it prints an extra blank prompt on the device's own screen
    /// — but it's indistinguishable from real activity to whatever
    /// `exec-timeout`-style idle clock the device is running, and it works
    /// identically on every vendor's CLI since it's just a keystroke, not a
    /// protocol-level SSH feature the device has to specifically support.
    private func sendKeepaliveNewline() async {
        guard let stdinWriter else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: 1)
        buffer.writeString("\n")
        try? await stdinWriter.write(buffer)
        lastActivityAt = Date()
    }

    /// Opens a second, independent SFTP session on the same underlying SSH
    /// connection — used by SFTPBrowserView. Independent from the PTY shell
    /// channel, so browsing files doesn't interrupt the interactive session.
    func openSFTPBrowser() async throws -> SFTPBrowserSession {
        guard let client else { throw SessionError.notConnected }
        let sftp = try await client.openSFTP()
        return SFTPBrowserSession(sftp: sftp)
    }

    enum SessionError: LocalizedError {
        case missingPrivateKeyPath
        case privateKeyNotFound(path: String)
        case privateKeyFormatUnsupported(reason: String)
        case privateKeyLoadFailed(passphraseProvided: Bool)
        case agentAuthNotYetImplemented
        case notConnected
        case hostKeyMismatch(previousFingerprint: String, newFingerprint: String)

        var errorDescription: String? {
            switch self {
            case .missingPrivateKeyPath:
                return "No private key file is set for this session."
            case .privateKeyNotFound(let path):
                return "Couldn't find a private key file at \(path)."
            case .privateKeyFormatUnsupported(let reason):
                return "This private key isn't usable yet: \(reason)"
            case .privateKeyLoadFailed(let passphraseProvided):
                return passphraseProvided
                    ? "Couldn't decrypt this private key. Double-check the passphrase."
                    : "This private key appears to be passphrase-protected. Enter its passphrase in the session's Key Passphrase field and try again."
            case .agentAuthNotYetImplemented:
                return "SSH agent authentication isn't implemented yet — use password or private key auth instead."
            case .notConnected:
                return "Not connected."
            case .hostKeyMismatch(let previousFingerprint, let newFingerprint):
                return "The host key for this server changed since last time (expected \(previousFingerprint), got \(newFingerprint)). This can mean the server was reinstalled, or that something is intercepting the connection — only continue if you're sure."
            }
        }
    }

    /// Bridges NIOSSH's host-key callback to `KnownHostsStore`. TOFU: the
    /// first key seen for a host:port is trusted and remembered; a later
    /// mismatch fails the handshake instead of silently accepting it, which
    /// is what `.acceptAnything()` used to do for every connection.
    private final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
        let host: String
        let port: Int
        let trustOverride: Bool

        init(host: String, port: Int, trustOverride: Bool) {
            self.host = host
            self.port = port
            self.trustOverride = trustOverride
        }

        func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
            var buffer = ByteBuffer()
            _ = hostKey.write(to: &buffer)
            let rawKeyBytes = Data(buffer: buffer)

            switch KnownHostsStore.shared.evaluate(host: host, port: port, rawKeyBytes: rawKeyBytes) {
            case .newHost:
                KnownHostsStore.shared.trust(host: host, port: port, rawKeyBytes: rawKeyBytes)
                validationCompletePromise.succeed(())
            case .matches:
                validationCompletePromise.succeed(())
            case .mismatch(let previousFingerprint):
                if trustOverride {
                    KnownHostsStore.shared.trust(host: host, port: port, rawKeyBytes: rawKeyBytes)
                    validationCompletePromise.succeed(())
                } else {
                    let newFingerprint = KnownHostsStore.shared.fingerprint(of: rawKeyBytes)
                    validationCompletePromise.fail(
                        SessionError.hostKeyMismatch(previousFingerprint: previousFingerprint, newFingerprint: newFingerprint)
                    )
                }
            }
        }
    }
}
