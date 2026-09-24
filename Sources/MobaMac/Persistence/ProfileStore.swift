import Foundation
import Combine

/// Loads and saves session profiles + groups as JSON in
/// ~/Library/Application Support/MobaMac/profiles.json.
/// Deliberately simple for the MVP — swap for Core Data/SQLite later
/// if the profile list grows into the thousands.
final class ProfileStore: ObservableObject {
    @Published var profiles: [SessionProfile] = []
    @Published var groups: [SessionGroup] = []

    private let fileURL: URL
    private let keychain = KeychainService()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("MobaMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("profiles.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode(StoredData.self, from: data) else { return }
        self.profiles = decoded.profiles
        self.groups = decoded.groups
    }

    func save() {
        let payload = StoredData(profiles: profiles, groups: groups)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Creates or updates a profile. `secret` (password / key passphrase) goes
    /// to the Keychain, not into the JSON payload — pass nil to leave it untouched.
    func upsert(_ profile: SessionProfile, secret: String?) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        if let secret, !secret.isEmpty {
            try? keychain.setSecret(secret, for: profile.id)
        }
        save()
    }

    func delete(_ profile: SessionProfile) {
        profiles.removeAll { $0.id == profile.id }
        try? keychain.deleteSecret(for: profile.id)
        save()
    }

    func secret(for profile: SessionProfile) -> String? {
        try? keychain.getSecret(for: profile.id)
    }

    /// A copy of `profile` ready to be opened in the Duplicate sheet: a new
    /// id, no `lastConnectedAt` so it doesn't appear under Recent before it
    /// has ever been used, and a name that doesn't collide.
    ///
    /// Nothing is saved here. The copy only becomes a profile if the sheet
    /// is saved, which is why the secret comes back to the caller instead of
    /// being written to the Keychain under the new id — a cancelled
    /// duplicate would otherwise leave a password behind for a profile that
    /// never existed.
    ///
    /// That secret is the part worth being careful about. Passwords are
    /// keyed by `profile.id`, and the copy has a new one, so a duplicate
    /// that copied only the struct would try to log in with no password at
    /// all. That reads as a bug in the connection code rather than in the
    /// copy, which is exactly the kind of thing that costs an afternoon.
    func duplicate(_ profile: SessionProfile) -> (profile: SessionProfile, secret: String?) {
        var copy = profile
        copy.id = UUID()
        copy.lastConnectedAt = nil
        copy.name = duplicateName(basedOn: profile.name)
        // A profile that logs in from a credential set has no secret of its
        // own to carry across: the copy keeps the same `credentialSetID` and
        // follows the same set. This is the common case and the clean one.
        let secret = profile.credentialSetID == nil ? self.secret(for: profile) : nil
        return (copy, secret)
    }

    /// "sw-dist01 copy", then "sw-dist01 copy 2" and upwards.
    private func duplicateName(basedOn name: String) -> String {
        let base = "\(name) copy"
        guard profiles.contains(where: { $0.name == base }) else { return base }
        var suffix = 2
        while profiles.contains(where: { $0.name == "\(base) \(suffix)" }) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    func addGroup(named name: String, parentID: UUID? = nil) {
        groups.append(SessionGroup(name: name, parentID: parentID))
        save()
    }

    /// Top-level (customer) groups only — feeds the Customer combo box and
    /// the sidebar's outer tree level. `SessionGroup.parentID == nil` is
    /// what marks a group as top-level.
    var customerGroups: [SessionGroup] {
        groups.filter { $0.parentID == nil }
    }

    /// The "Customer" groups directly under `parentID`, i.e. the "Device
    /// Type" level of the tree.
    func deviceTypeGroups(under parentID: UUID) -> [SessionGroup] {
        groups.filter { $0.parentID == parentID }
    }

    /// Finds or creates a standalone top-level (customer) folder. Split out
    /// of `findOrCreateGroup` below so a folder can be laid out on its own
    /// — via `NewFolderSheet` — before any session exists to put in it,
    /// instead of a folder only ever coming into being as a side effect of
    /// saving a session profile. Case-insensitive match, same reasoning as
    /// `findOrCreateGroup`.
    @discardableResult
    func findOrCreateCustomerGroup(named name: String) -> UUID {
        let customerName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = groups.first(where: {
            $0.parentID == nil && $0.name.caseInsensitiveCompare(customerName) == .orderedSame
        }) {
            return existing.id
        }
        let created = SessionGroup(name: customerName, parentID: nil)
        groups.append(created)
        save()
        return created.id
    }

    /// Finds or creates a device-type folder nested one level under an
    /// existing customer group id. Counterpart to
    /// `findOrCreateCustomerGroup` for the tree's second level.
    @discardableResult
    func findOrCreateDeviceTypeGroup(named name: String, under customerID: UUID) -> UUID {
        let deviceTypeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = groups.first(where: {
            $0.parentID == customerID && $0.name.caseInsensitiveCompare(deviceTypeName) == .orderedSame
        }) {
            return existing.id
        }
        let created = SessionGroup(name: deviceTypeName, parentID: customerID)
        groups.append(created)
        save()
        return created.id
    }

    /// Given a customer name and a device type name, finds or creates the
    /// matching nested `SessionGroup` pair (customer as top-level, device
    /// type as its child). Returns the device-type group's id — that's what
    /// goes on `SessionProfile.groupID`. Built on the two helpers above so
    /// there's exactly one place that decides what counts as a "match".
    @discardableResult
    func findOrCreateGroup(customer: String, deviceType: String) -> UUID {
        let customerID = findOrCreateCustomerGroup(named: customer)
        return findOrCreateDeviceTypeGroup(named: deviceType, under: customerID)
    }

    /// Number of session profiles directly filed under a given group id —
    /// what `ManageFoldersView` shows next to each folder before you delete
    /// it, so "delete" doesn't come as a surprise.
    func profileCount(in groupID: UUID) -> Int {
        profiles.filter { $0.groupID == groupID }.count
    }

    /// Renames a folder in place — same rename for either tree level, since
    /// both are just a `SessionGroup` with a different `parentID` shape.
    func renameGroup(_ group: SessionGroup, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].name = trimmed
        save()
    }

    /// Deletes a folder. A Customer folder also removes its Device Type
    /// children; either way, any session profile that was filed under the
    /// deleted folder(s) falls back to Ungrouped rather than being deleted
    /// itself — a folder is just an organizing label, not a container the
    /// way a profile's actual host/credentials are.
    func deleteGroup(_ group: SessionGroup) {
        var idsToRemove: Set<UUID> = [group.id]
        if group.parentID == nil {
            idsToRemove.formUnion(deviceTypeGroups(under: group.id).map(\.id))
        }
        groups.removeAll { idsToRemove.contains($0.id) }
        for index in profiles.indices where profiles[index].groupID.map({ idsToRemove.contains($0) }) == true {
            profiles[index].groupID = nil
        }
        save()
    }

    /// Walks a group's `parentID` chain to build a "Customer / Device Type"
    /// breadcrumb string — used by the sidebar tree's search results and the
    /// command palette. Returns nil for an ungrouped profile.
    func breadcrumb(for groupID: UUID?) -> String? {
        guard let groupID else { return nil }
        var names: [String] = []
        var currentID: UUID? = groupID
        var hops = 0
        while let id = currentID, hops < 10 {
            guard let group = groups.first(where: { $0.id == id }) else { break }
            names.append(group.name)
            currentID = group.parentID
            hops += 1
        }
        guard !names.isEmpty else { return nil }
        return names.reversed().joined(separator: " / ")
    }

    /// The device-type folder a session sits in, which is the second level
    /// of the tree. A group with no parent is a customer, not a device type,
    /// so it returns nil there.
    func deviceTypeName(for groupID: UUID?) -> String? {
        guard let groupID, let group = groups.first(where: { $0.id == groupID }) else { return nil }
        return group.parentID == nil ? nil : group.name
    }

    /// Walks a group's `parentID` chain up to its top-level (customer)
    /// ancestor. Used to decide "is this session under the same customer as
    /// that one" for broadcast's default-checked rule.
    func topLevelCustomerID(for groupID: UUID?) -> UUID? {
        var currentID = groupID
        var hops = 0
        while let id = currentID, hops < 10 {
            guard let group = groups.first(where: { $0.id == id }) else { return nil }
            if group.parentID == nil { return group.id }
            currentID = group.parentID
            hops += 1
        }
        return nil
    }

    private struct StoredData: Codable {
        var profiles: [SessionProfile]
        var groups: [SessionGroup]
    }
}
