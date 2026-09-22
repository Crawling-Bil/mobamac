import SwiftUI

/// Full Customer/Device-Type folder manager — the "see and manage
/// everything at once" step past `NewFolderSheet`'s one-shot creation.
/// Add, rename, or delete folders here without touching a session profile
/// at all; the sidebar tree and `NewSessionSheet`'s Customer/Device Type
/// fields read from the exact same `ProfileStore.groups`, so anything
/// built here is immediately what you pick from when you do add a session.
/// Deleting a folder never deletes the sessions inside it — they fall back
/// to "Ungrouped" in the sidebar, same as a profile whose group vanished
/// any other way.
struct ManageFoldersView: View {
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var newCustomerName = ""
    @State private var addingDeviceTypeUnder: SessionGroup?
    @State private var newDeviceType: DeviceTypeOption = .router
    @State private var renamingGroup: SessionGroup?
    @State private var renameText = ""
    @State private var groupPendingDelete: SessionGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Folders").font(.title2.bold())
            Text("Customer and Device Type folders for the sidebar tree. Deleting a folder doesn't delete its sessions. They move to Ungrouped.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if profileStore.customerGroups.isEmpty {
                Text("No folders yet. Add a customer below to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(profileStore.customerGroups.sorted { $0.name < $1.name }) { customer in
                        Section {
                            ForEach(profileStore.deviceTypeGroups(under: customer.id).sorted { $0.name < $1.name }) { deviceType in
                                deviceTypeRow(deviceType)
                            }
                            addOrDeviceTypeButton(under: customer)
                        } header: {
                            customerHeader(customer)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 320)
            }

            HStack {
                TextField("New customer name", text: $newCustomerName)
                    .onSubmit(addCustomer)
                Button("Add Customer") { addCustomer() }
                    .disabled(newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
        .alert(
            "Rename Folder",
            isPresented: Binding(
                get: { renamingGroup != nil },
                set: { if !$0 { renamingGroup = nil } }
            ),
            presenting: renamingGroup
        ) { group in
            TextField("Name", text: $renameText)
            Button("Save") {
                profileStore.renameGroup(group, to: renameText)
                renamingGroup = nil
            }
            Button("Cancel", role: .cancel) { renamingGroup = nil }
        }
        .confirmationDialog(
            "Delete \(groupPendingDelete?.name ?? "")?",
            isPresented: Binding(
                get: { groupPendingDelete != nil },
                set: { if !$0 { groupPendingDelete = nil } }
            ),
            presenting: groupPendingDelete
        ) { group in
            Button("Delete", role: .destructive) {
                profileStore.deleteGroup(group)
                groupPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { groupPendingDelete = nil }
        } message: { group in
            Text(deleteMessage(for: group))
        }
    }

    private func customerHeader(_ customer: SessionGroup) -> some View {
        HStack {
            Label(customer.name, systemImage: "building.2")
                .font(.headline)
            Spacer()
            Button {
                renamingGroup = customer
                renameText = customer.name
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Rename this customer folder.")
            Button {
                groupPendingDelete = customer
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this customer folder and its device-type folders.")
        }
    }

    private func deviceTypeRow(_ deviceType: SessionGroup) -> some View {
        let count = profileStore.profileCount(in: deviceType.id)
        return HStack {
            Label(deviceType.name, systemImage: "folder")
            Spacer()
            Text("\(count) session\(count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                groupPendingDelete = deviceType
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this device-type folder.")
        }
    }

    @ViewBuilder
    private func addOrDeviceTypeButton(under customer: SessionGroup) -> some View {
        if addingDeviceTypeUnder?.id == customer.id {
            HStack {
                Picker("", selection: $newDeviceType) {
                    ForEach(DeviceTypeOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .labelsHidden()
                Button("Add") {
                    profileStore.findOrCreateDeviceTypeGroup(named: newDeviceType.rawValue, under: customer.id)
                    addingDeviceTypeUnder = nil
                }
                Button("Cancel") { addingDeviceTypeUnder = nil }
            }
        } else {
            Button {
                addingDeviceTypeUnder = customer
                newDeviceType = .router
            } label: {
                Label("Add Device Type…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    private func addCustomer() {
        let trimmed = newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profileStore.findOrCreateCustomerGroup(named: trimmed)
        newCustomerName = ""
    }

    private func deleteMessage(for group: SessionGroup) -> String {
        if group.parentID == nil {
            let deviceTypes = profileStore.deviceTypeGroups(under: group.id)
            let sessionCount = deviceTypes.reduce(0) { $0 + profileStore.profileCount(in: $1.id) }
            return "This removes the \"\(group.name)\" folder and its \(deviceTypes.count) device-type folder\(deviceTypes.count == 1 ? "" : "s"). \(sessionCount) session\(sessionCount == 1 ? "" : "s") will move to Ungrouped, not be deleted."
        } else {
            let sessionCount = profileStore.profileCount(in: group.id)
            return "\(sessionCount) session\(sessionCount == 1 ? "" : "s") in this folder will move to Ungrouped, not be deleted."
        }
    }
}
