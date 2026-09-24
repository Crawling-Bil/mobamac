import Foundation

/// A reusable SSH identity (UI spec §9.4): a username + auth method that
/// many session profiles can share, so rotating a password or swapping a
/// key updates every device that logs in with it instead of requiring an
/// edit per profile. Deliberately mirrors the login-relevant slice of
/// `SessionProfile` (username/authMethod/privateKeyPath) rather than
/// wrapping it, since a credential set has no host/port/kind of its own —
/// it's purely "who you log in as," attached to a profile via
/// `SessionProfile.credentialSetID`.
///
/// The actual secret (password / key passphrase) lives in the Keychain
/// exactly like a profile's own secret does, keyed by this set's own `id`
/// via the same `KeychainService` — never in this struct or the JSON it's
/// saved in.
struct CredentialSet: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var username: String
    var authMethod: AuthMethod
    var privateKeyPath: String?
    /// Startup commands for every session that uses this set, unless that
    /// session defines its own. One place to put "terminal length 0" for a
    /// whole customer's estate.
    var startupCommands: String?

    init(
        id: UUID = UUID(),
        name: String,
        username: String = "",
        authMethod: AuthMethod = .password,
        privateKeyPath: String? = nil,
        startupCommands: String? = nil
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.startupCommands = startupCommands
    }
}
