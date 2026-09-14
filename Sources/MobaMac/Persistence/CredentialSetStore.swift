import Foundation

/// Loads and saves credential sets (UI spec §9.4) as JSON in
/// ~/Library/Application Support/MobaMac/credential-sets.json. Kept as its
/// own small store rather than folded into `ProfileStore` — a credential
/// set isn't a kind of profile, it's a separate object profiles *reference*
/// (`SessionProfile.credentialSetID`), with its own independent lifecycle:
/// it can be created, edited, or deleted without touching any profile
/// directly.
final class CredentialSetStore: ObservableObject {
    @Published var credentialSets: [CredentialSet] = []

    private let fileURL: URL
    private let keychain = KeychainService()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("MobaMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("credential-sets.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([CredentialSet].self, from: data) else { return }
        self.credentialSets = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(credentialSets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Creates or updates a credential set. `secret` (password / key
    /// passphrase) goes to the Keychain, not into the JSON payload — pass
    /// nil to leave it untouched, exactly like `ProfileStore.upsert`.
    func upsert(_ credentialSet: CredentialSet, secret: String?) {
        if let index = credentialSets.firstIndex(where: { $0.id == credentialSet.id }) {
            credentialSets[index] = credentialSet
        } else {
            credentialSets.append(credentialSet)
        }
        if let secret, !secret.isEmpty {
            try? keychain.setSecret(secret, for: credentialSet.id)
        }
        save()
    }

    func delete(_ credentialSet: CredentialSet) {
        credentialSets.removeAll { $0.id == credentialSet.id }
        try? keychain.deleteSecret(for: credentialSet.id)
        save()
    }

    func secret(for credentialSet: CredentialSet) -> String? {
        try? keychain.getSecret(for: credentialSet.id)
    }

    func credentialSet(id: UUID?) -> CredentialSet? {
        guard let id else { return nil }
        return credentialSets.first { $0.id == id }
    }
}
