import SwiftUI

/// Explicit "add a folder" flow for the sidebar tree. Until now the only
/// way a Customer/Device-Type folder came into existence was as a side
/// effect of saving a session profile with those fields filled in on
/// `NewSessionSheet` — fine once you already have a device to add, but
/// there was no way to lay out empty folders ahead of time, and
/// `ProfileStore.addGroup` sat there unused because nothing in the UI ever
/// called it. This is what actually wires it up: pick or type a Customer,
/// optionally add a Device Type folder under it, done.
struct NewFolderSheet: View {
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var customer: String
    @State private var addDeviceType: Bool
    @State private var deviceType: DeviceTypeOption = .router

    /// `presetCustomer` lets the sidebar's "Add Device Type Folder…" context
    /// menu (on an existing Customer folder) jump straight to naming the
    /// device type, instead of making the user retype a customer name that's
    /// already sitting right there in the tree.
    init(presetCustomer: String? = nil) {
        _customer = State(initialValue: presetCustomer ?? "")
        _addDeviceType = State(initialValue: presetCustomer != nil)
    }

    private var isValid: Bool {
        !customer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Folder").font(.title2.bold())

            HStack(spacing: 2) {
                TextField("Customer", text: $customer)
                Menu {
                    ForEach(profileStore.customerGroups.sorted { $0.name < $1.name }) { group in
                        Button(group.name) { customer = group.name }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(profileStore.customerGroups.isEmpty)
            }
            .help("Type a new customer to start a top-level folder, or pick an existing one to add a Device Type folder under it.")

            Toggle("Add a Device Type folder too", isOn: $addDeviceType)

            if addDeviceType {
                Picker("Device Type", selection: $deviceType) {
                    ForEach(DeviceTypeOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            }

            Text("Sessions saved later with this Customer (and Device Type) will land in this folder automatically. This just lets you lay it out ahead of time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private func create() {
        let customerID = profileStore.findOrCreateCustomerGroup(named: customer)
        if addDeviceType {
            profileStore.findOrCreateDeviceTypeGroup(named: deviceType.rawValue, under: customerID)
        }
        dismiss()
    }
}
