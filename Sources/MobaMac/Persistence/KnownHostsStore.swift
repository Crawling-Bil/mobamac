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
    private var entries: [String: String] // "host:port" -> fingerprint

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

    func evaluate(host: String, port: Int, rawKeyBytes: Data) -> Verdict {
        let key = "\(host):\(port)"
        let fp = fingerprint(of: rawKeyBytes)
        guard let known = entries[key] else { return .newHost }
        return known == fp ? .matches : .mismatch(previousFingerprint: known)
    }

    func trust(host: String, port: Int, rawKeyBytes: Data) {
        entries["\(host):\(port)"] = fingerprint(of: rawKeyBytes)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
