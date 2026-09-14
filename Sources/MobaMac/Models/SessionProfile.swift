import Foundation

enum SessionKind: String, Codable, CaseIterable, Identifiable {
    case ssh
    case local
    case telnet
    case serial

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ssh: return "SSH"
        case .local: return "Local Terminal"
        case .telnet: return "Telnet"
        case .serial: return "Serial"
        }
    }
}

/// A saved connection profile — roughly a MobaXterm "session".
/// Secrets (password, key passphrase) live in the Keychain, keyed by `id`,
/// never in this struct or the JSON file it's persisted in.
///
/// `serialPortPath`/`baudRate` are optional even though every `.serial`
/// profile needs them — that's deliberate, not laziness: profiles saved
/// before Serial support existed have no such keys in their JSON, and
/// Swift's synthesized `Decodable` only tolerates a missing key for an
/// Optional property. Treat a nil `baudRate` as 9600 wherever it's read.
struct SessionProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var kind: SessionKind
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var privateKeyPath: String?
    var serialPortPath: String?
    var baudRate: Int?
    /// Terminal color theme id (see `TerminalTheme`) — optional for the same
    /// backward-compat reason as the Serial fields above: profiles saved
    /// before themes existed have no such key. A nil/unknown id falls back
    /// to `TerminalTheme.default`.
    var themeID: String?
    var groupID: UUID?
    var lastConnectedAt: Date?
    /// SSH idle-keepalive interval in seconds (UI spec §9.1) — nil means
    /// "use the default" (30s), 0 means off. Kept separate from "unset"
    /// so a profile can explicitly disable keepalives (some hardened
    /// environments log them as activity) without that reading the same
    /// as a profile that predates this feature entirely.
    var keepaliveInterval: Int?
    /// References a `CredentialSet` (UI spec §9.4) instead of this
    /// profile's own `username`/secret. When set, `SessionManager` resolves
    /// the actual username/secret from the credential set at connect time;
    /// when nil, current per-profile behavior is unchanged — additive, so
    /// nothing that already works can break.
    var credentialSetID: UUID?
    /// Auto-reconnect toggle (UI spec §9.2) — off by default. Retrying into
    /// a device that's mid-reboot can catch it in a half-booted state, so
    /// this has to be an explicit opt-in per profile, not a global default.
    var autoReconnect: Bool?

    init(
        id: UUID = UUID(),
        name: String,
        kind: SessionKind = .ssh,
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: AuthMethod = .password,
        privateKeyPath: String? = nil,
        serialPortPath: String? = nil,
        baudRate: Int? = nil,
        themeID: String? = nil,
        groupID: UUID? = nil,
        lastConnectedAt: Date? = nil,
        keepaliveInterval: Int? = nil,
        credentialSetID: UUID? = nil,
        autoReconnect: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.serialPortPath = serialPortPath
        self.baudRate = baudRate
        self.themeID = themeID
        self.groupID = groupID
        self.lastConnectedAt = lastConnectedAt
        self.keepaliveInterval = keepaliveInterval
        self.credentialSetID = credentialSetID
        self.autoReconnect = autoReconnect
    }
}
