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

    /// UI spec §9.1: a device's idle `exec-timeout` (commonly 5 to 10
    /// minutes) drops a session that's just sitting there while someone
    /// reads a doc. After the configured idle interval `keepaliveTask`
    /// types a single newline. It has to be real input: exec-timeout
    /// counts EXEC input, so an SSH-level keepalive would not reset it.
    ///
    /// A newline is also exactly how a device confirms "reload" or
    /// "write erase", so `keepaliveGuard` decides whether it's safe:
    /// idle in both directions, nothing half-typed, and an ordinary prompt
    /// on screen. See KeepaliveGuard.
    private var keepaliveTask: Task<Void, Never>?
    private let keepaliveGuard = KeepaliveGuard()

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

        var settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { authMethod },
            hostKeyValidator: .custom(
                HostKeyValidator(host: profile.host, port: profile.port, trustOverride: trustNewHostKey)
            )
        )
        // Plain `SSHAlgorithms()` only offers the host key types NIOSSH
        // bundles (ed25519, ECDSA). A lot of network devices only have an RSA
        // host key, the Cisco switches MobaMac targets included, and against
        // those the key exchange fails with no algorithm in common. `.all`
        // registers Citadel's ssh-rsa host key support plus aes128-ctr and
        // diffie-hellman-group14. It appends to the preference lists rather
        // than replacing them, so devices that negotiated fine before still
        // pick exactly what they picked before.
        settings.algorithms = .all

        // NOTE: do not switch this to `SSHClient.connect(on: channel,)` in
        // order to slip an extra ChannelHandler in front of NIOSSHHandler
        // (the obvious way to rewrite an "SSH-1.99" version banner into
        // "SSH-2.0"). It was tried in 1.4/1.6 and broke every SSH
        // connection. Citadel's `connect(on:)` calls
        // `pipeline.syncOperations.addHandlers(...)` straight from the
        // async caller's thread rather than hopping to the event loop, and
        // the only thing stopping that is an `assertInEventLoop()` that
        // release builds compile out. So NIOSSHHandler.handlerAdded, and
        // with it the write and flush of our own version string, all run
        // off the event loop, and `ChannelHandlerContext.flush()`/`read()`
        // don't hop either. The handshake then stalls until Citadel's 10s
        // login timeout fires. `connect(to:)` below installs the same
        // handlers from inside the bootstrap's channelInitializer, which
        // does run on the event loop. A banner rewrite couldn't have worked
        // anyway: the server's version string is hashed into the key
        // exchange, so changing it breaks the host key signature. "1.99"
        // support lives in Vendor/swift-nio-ssh instead, which accepts the
        // banner as-is.
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
                    self.startKeepaliveIfNeeded()
                    for try await chunk in ttyOutput {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            let data = Data(buffer: buffer)
                            self.keepaliveGuard.recordOutput(data)
                            self.onOutput?(data)
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
                    reason: "\(keyType.description) keys aren't supported yet. Only RSA and Ed25519 OpenSSH keys are."
                )
            }
        } catch let error as SessionError {
            throw error
        } catch {
            throw SessionError.privateKeyLoadFailed(passphraseProvided: hasPassphrase)
        }
    }

    func send(_ data: Data) async {
        keepaliveGuard.recordInput(data)
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
                if self.keepaliveGuard.shouldSendKeepalive(idleThreshold: Double(interval)) {
                    await self.sendKeepaliveNewline()
                }
            }
        }
    }

    /// The keepalive itself: a bare newline on the PTY's stdin, which prints
    /// one extra prompt line on the device. Only ever called after
    /// `keepaliveGuard.shouldSendKeepalive` said yes.
    private func sendKeepaliveNewline() async {
        guard let stdinWriter else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: 1)
        buffer.writeString("\n")
        try? await stdinWriter.write(buffer)
        keepaliveGuard.recordKeepaliveSent()
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
                return "SSH agent authentication isn't supported yet. Use a password or private key instead."
            case .notConnected:
                return "Not connected."
            case .hostKeyMismatch(let previousFingerprint, let newFingerprint):
                return "The host key for this server changed since last time (expected \(previousFingerprint), got \(newFingerprint)). This can mean the server was reinstalled, or that something is intercepting the connection. Only continue if you're sure."
            }
        }
    }
}

/// `NIOSSHError` doesn't conform to `LocalizedError`, so left alone it
/// bridges to a generic, useless `NSError` string like "The operation
/// couldn't be completed. (NIOSSH.NIOSSHError error 1.)" — that "1" is
/// not meaningful; every `NIOSSHError` bridges to the same code since
/// the type has no custom `CustomNSError` conformance. The real
/// diagnostic lives in `.type`/`.description`, which this maps into
/// something the user can act on — especially the handshake-level
/// failures that show up when talking to network devices (routers,
/// switches, firewalls) that only offers legacy/weak SSH algorithms
/// this library intentionally refuses to use.
extension NIOSSHError {
    var friendlyDescription: String {
        switch self.type {
        case .weakSharedSecret:
            return "The SSH key exchange produced a weak shared secret and was rejected. This usually means the device only offers an outdated Diffie-Hellman group, which is common on older routers, switches and firewalls. Check the device's SSH settings for a modern key-exchange algorithm (e.g. curve25519-sha256 or diffie-hellman-group14-sha256) and enable it if available."
        case .keyExchangeNegotiationFailure:
            return "This device and MobaMac have no SSH algorithm in common. Either side can be the cause: older devices may only offer algorithms this app refuses (such as diffie-hellman-group1-sha1), while hardened devices may offer only RSA host keys signed with rsa-sha2-256/512, which MobaMac can't verify yet (it supports RSA host keys only as ssh-rsa). \"ssh -vv <user>@<host>\" from Terminal prints the device's offered lists under \"peer server KEXINIT proposal\"."
        case .unsupportedVersion:
            if self.description.contains("SSH-1.99") {
                // Unreachable in a normal build: the vendored SSH library
                // accepts "1.99". Seeing this means the app was built against
                // the unpatched upstream library instead. The message stays
                // free of source paths, which mean nothing to whoever is
                // looking at a failed connection.
                return "This device reports SSH version 1.99. This build of MobaMac can't accept that version. Install the latest release, or run \"ip ssh version 2\" on the device as a workaround."
            }
            return "This device's SSH version isn't supported (this app requires SSH-2.0). Devices that only support SSH-1 can't be used with this connection type."
        case .invalidHostKeyForKeyExchange, .invalidExchangeHashSignature:
            return "The device's host key didn't match what was negotiated during the handshake. This can mean something between you and the device is intercepting the connection, or the device's SSH implementation is faulty."
        case .tcpShutdown:
            return "The connection closed unexpectedly during the SSH handshake. Check that nothing (a firewall, VPN, or the device itself) is dropping the connection partway through, and that the device is actually reachable on this network."
        case .invalidUserAuthSignature:
            return "The device rejected the authentication signature. Double-check the username/password or key configured for this session."
        default:
            return "SSH error: \(self.description). This is usually a protocol- or algorithm-level mismatch with the device rather than a plain network issue."
        }
    }
}

@available(macOS 15.0, *)
extension SSHConnectionSession {
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
