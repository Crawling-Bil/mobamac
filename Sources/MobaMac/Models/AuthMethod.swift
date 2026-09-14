import Foundation

/// How a session authenticates to the remote host.
/// The actual secret (password / key passphrase) is never stored here —
/// only a reference to where it lives in the Keychain. See KeychainService.
enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case privateKey
    case agent // relies on ssh-agent / keys already loaded — not wired up yet, see README

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: return "Password"
        case .privateKey: return "Private Key"
        case .agent: return "SSH Agent"
        }
    }
}
