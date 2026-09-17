import SwiftUI

/// Management sheet for credential sets (UI spec §9.4) — reachable from the
/// "Credential Set" picker in New/Edit Session ("Manage…") rather than a
/// dedicated toolbar icon, since this is a supporting/setup screen for that
/// picker rather than something reached mid-session the way Snippets or
/// Logs are.
struct CredentialSetsView: View {
    @EnvironmentObject var credentialSetStore: CredentialSetStore
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var editingSet: CredentialSet?
    @State private var showingNew = false
    @State private var setPendingDelete: CredentialSet?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Credential Sets").font(.title2.bold())
                Spacer()
                Button {
                    showingNew = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                Button("Close") { dismiss() }
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            if credentialSetStore.credentialSets.isEmpty {
                VStack(spacing: 8) {
                    Text("No credential sets yet").font(.headline)
                    Text("Save a username and login once, then reuse it across every session profile that logs in the same way.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(credentialSetStore.credentialSets) { set in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(set.name).font(.body.bold())
                                Text("\(set.username.isEmpty ? "(no username)" : set.username) · \(set.authMethod.displayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            let usageCount = usageCount(for: set)
                            if usageCount > 0 {
                                Text("\(usageCount) profile\(usageCount == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                    .help("Used by \(usageCount) session profile\(usageCount == 1 ? "" : "s").")
                            }
                            Button {
                                editingSet = set
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("Edit this credential set.")
                            Button {
                                setPendingDelete = set
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete this credential set.")
                        }
                    }
                }
            }
        }
        .frame(width: 460, height: 360)
        .sheet(isPresented: $showingNew) {
            CredentialSetEditSheet(setToEdit: nil)
        }
        .sheet(item: $editingSet) { set in
            CredentialSetEditSheet(setToEdit: set)
        }
        .confirmationDialog(
            "Delete \"\(setPendingDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { setPendingDelete != nil },
                set: { if !$0 { setPendingDelete = nil } }
            ),
            presenting: setPendingDelete
        ) { set in
            Button("Delete", role: .destructive) {
                credentialSetStore.delete(set)
                setPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { setPendingDelete = nil }
        } message: { set in
            let count = usageCount(for: set)
            Text(count > 0
                 ? "\(count) session profile\(count == 1 ? "" : "s") still use this. They'll fall back to their own saved username and password until you pick a different credential set or fill those fields back in."
                 : "This can't be undone.")
        }
    }

    private func usageCount(for set: CredentialSet) -> Int {
        profileStore.profiles.filter { $0.credentialSetID == set.id }.count
    }
}

private struct CredentialSetEditSheet: View {
    @EnvironmentObject var credentialSetStore: CredentialSetStore
    @Environment(\.dismiss) private var dismiss

    private let editingID: UUID?
    @State private var name: String
    @State private var username: String
    @State private var authMethod: AuthMethod
    @State private var privateKeyPath: String
    @State private var secret = ""

    init(setToEdit: CredentialSet?) {
        editingID = setToEdit?.id
        _name = State(initialValue: setToEdit?.name ?? "")
        _username = State(initialValue: setToEdit?.username ?? "")
        _authMethod = State(initialValue: setToEdit?.authMethod ?? .password)
        _privateKeyPath = State(initialValue: setToEdit?.privateKeyPath ?? "")
    }

    private var isEditing: Bool { editingID != nil }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? "Edit Credential Set" : "New Credential Set").font(.title2.bold())
            TextField("Name (e.g. \"Datacenter admin\")", text: $name)
            TextField("Username", text: $username)

            Picker("Auth", selection: $authMethod) {
                ForEach(AuthMethod.allCases) { Text($0.displayName).tag($0) }
            }

            switch authMethod {
            case .password:
                SecureField(isEditing ? "Password (leave blank to keep current)" : "Password", text: $secret)
            case .privateKey:
                TextField("Private key path", text: $privateKeyPath)
                SecureField(isEditing ? "Key passphrase (leave blank to keep current)" : "Key passphrase (leave blank if the key isn't encrypted)", text: $secret)
            case .agent:
                Text("Uses keys already loaded in ssh-agent.")
                    .foregroundStyle(.secondary)
            }

            Text("Any session profile that picks this credential set will log in with this username and secret instead of its own, and stays in sync if you change it here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isEditing ? "Save Changes" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func save() {
        let set = CredentialSet(
            id: editingID ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username,
            authMethod: authMethod,
            privateKeyPath: authMethod == .privateKey ? privateKeyPath : nil
        )
        credentialSetStore.upsert(set, secret: secret.isEmpty ? nil : secret)
        dismiss()
    }
}
