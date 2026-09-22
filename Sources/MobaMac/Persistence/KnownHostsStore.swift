import Foundation
import CryptoKit

/// Trust-on-first-use (TOFU) storage for remote host key fingerprints —
/// same idea as ~/.ssh/known_hosts, scoped to this app.
///
/// WIRED IN: `SSHConnectionSession` calls `evaluate`/`trust` from a
/// `NIOSSHClientServerAuthenticationDelegate` passed as
/// `hostKeyValidator: .custom(...)` (see `SSHConnectionSession.HostKeyValidator`).
/// First connection to a host is trusted and remembered (TOFU); a later
/// mismatch fails the handshake with `SessionError.hostKeyMismatch` instead
/// of connecting anyway, and the UI offers an explicit "Trust New Key &
/// Reconnect" action rather than silently accepting the new key.
final class KnownHostsStore {
    static let shared = KnownHostsStore()

    enum Verdict: Equatable {
        case newHost
        case matches
        case mismatch(previousFingerprint: String)
    }

    private let fileURL: URL
    /// "host:port" -> fingerprint (SSH-1 keys use "host:port/ssh1", see
    /// `key(host:port:protocolTag:)`). Only touched while holding `lock`:
    /// `evaluate` and `trust` run on NIO event loop threads, and several
    /// sessions connecting at once can call them concurrently. Unguarded,
    /// that's a data race on the dictionary, which can crash or silently
    /// lose a trusted key.
    private var entries: [String: String]
    private let lock = NSLock()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("MobaMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("known_hosts.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = [:]
        }
    }

    /// SHA-256 fingerprint of raw host key bytes, OpenSSH-style formatting.
    func fingerprint(of rawKeyBytes: Data) -> String {
        let digest = SHA256.hash(data: rawKeyBytes)
        return "SHA256:" + Data(digest).base64EncodedString()
    }

    /// `protocolTag` keeps SSH-1 host keys apart from SSH-2 ones: a device
    /// that speaks both has a different key for each, and sharing one entry
    /// would report a false "host key changed" whenever MobaMac switched
    /// protocols.
    private static func key(host: String, port: Int, protocolTag: String?) -> String {
        let base = "\(host):\(port)"
        return protocolTag.map { "\(base)/\($0)" } ?? base
    }

    func evaluate(host: String, port: Int, rawKeyBytes: Data, protocolTag: String? = nil) -> Verdict {
        let key = Self.key(host: host, port: port, protocolTag: protocolTag)
        let fp = fingerprint(of: rawKeyBytes)
        lock.lock()
        let known = entries[key]
        lock.unlock()
        guard let known else { return .newHost }
        return known == fp ? .matches : .mismatch(previousFingerprint: known)
    }

    func trust(host: String, port: Int, rawKeyBytes: Data, protocolTag: String? = nil) {
        let key = Self.key(host: host, port: port, protocolTag: protocolTag)
        let fp = fingerprint(of: rawKeyBytes)
        lock.lock()
        defer { lock.unlock() }
        entries[key] = fp
        // Written inside the lock so two trusts can't interleave and leave
        // the file holding the older of the two snapshots.
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
