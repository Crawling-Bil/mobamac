import SwiftUI

/// Fixed, extendable device-type list for the New Session form's Device
/// Type dropdown (UI spec §5). Add cases here as new gear types come up —
/// the raw value is what actually gets stored as the device-type
/// `SessionGroup`'s name, so keep raw values human-readable.
enum DeviceTypeOption: String, CaseIterable, Identifiable {
    case firewall = "Firewall"
    case aSwitch = "Switch"
    case router = "Router"
    case wlc = "WLC"
    case others = "Others"

    var id: String { rawValue }
}

/// Also doubles as the "Edit Session" sheet: pass `profileToEdit` to
/// pre-fill the form and update that profile's id on save instead of
/// creating a new one.
struct NewSessionSheet: View {
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var credentialSetStore: CredentialSetStore
    @Environment(\.dismiss) private var dismiss

    private let editingID: UUID?
    private let editingGroupID: UUID?
    private let editingLastConnectedAt: Date?

    @State private var name: String
    @State private var kind: SessionKind
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var authMethod: AuthMethod
    @State private var secret = ""
    @State private var privateKeyPath: String
    @State private var serialPortPath: String
    @State private var baudRate: Int
    @State private var availableSerialPorts: [SerialPortLister.Port] = []
    @State private var themeID: String
    @State private var customer: String = ""
    @State private var deviceType: DeviceTypeOption = .router
    @State private var keepaliveInterval: String
    @State private var autoReconnect: Bool
    @State private var credentialSetID: UUID?
    @State private var showingCredentialSets = false

    init(profileToEdit: SessionProfile? = nil) {
        editingID = profileToEdit?.id
        editingGroupID = profileToEdit?.groupID
        editingLastConnectedAt = profileToEdit?.lastConnectedAt
        _name = State(initialValue: profileToEdit?.name ?? "")
        _kind = State(initialValue: profileToEdit?.kind ?? .ssh)
        _host = State(initialValue: profileToEdit?.host ?? "")
        _port = State(initialValue: profileToEdit.map { String($0.port) } ?? "22")
        _username = State(initialValue: profileToEdit?.username ?? "")
        _authMethod = State(initialValue: profileToEdit?.authMethod ?? .password)
        _privateKeyPath = State(initialValue: profileToEdit?.privateKeyPath ?? "")
        _serialPortPath = State(initialValue: profileToEdit?.serialPortPath ?? "")
        _baudRate = State(initialValue: profileToEdit?.baudRate ?? 9600)
        _themeID = State(initialValue: profileToEdit?.themeID ?? TerminalTheme.appDefault.id)
        _keepaliveInterval = State(initialValue: profileToEdit.map { String($0.keepaliveInterval ?? 30) } ?? "30")
        _autoReconnect = State(initialValue: profileToEdit?.autoReconnect ?? false)
        _credentialSetID = State(initialValue: profileToEdit?.credentialSetID)
    }

    private var isEditing: Bool { editingID != nil }

    private var usesHostAndPort: Bool { kind == .ssh || kind == .telnet }

    private var hostError: String? {
        usesHostAndPort ? HostValidator.hostErrorMessage(for: host) : nil
    }

    private var portError: String? {
        usesHostAndPort ? HostValidator.portErrorMessage(for: port) : nil
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .ssh, .telnet:
            return HostValidator.isValidHost(host) && HostValidator.isValidPort(port)
        case .serial:
            return !serialPortPath.isEmpty
        case .local:
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? "Edit Session" : "New Session").font(.title2.bold())

            protocolPickerRow

            TextField("Name", text: $name)

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
                .help("Pick an existing customer, or type a new one on the left.")
            }

            Picker("Device Type", selection: $deviceType) {
                ForEach(DeviceTypeOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }

            Picker("Type", selection: $kind) {
                ForEach(SessionKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            if usesHostAndPort {
                TextField("Host", text: $host)
                if let hostError {
                    Text(hostError).font(.caption).foregroundStyle(.red)
                }

                TextField("Port", text: $port)
                if let portError {
                    Text(portError).font(.caption).foregroundStyle(.red)
                }
            }

            if kind == .ssh {
                Picker("Credential Set", selection: $credentialSetID) {
                    Text("None (use fields below)").tag(UUID?.none)
                    ForEach(credentialSetStore.credentialSets) { set in
                        Text(set.name).tag(Optional(set.id))
                    }
                }
                .help("Reuse a saved username and login across many profiles instead of typing one in below — update it once here and every profile using it picks up the change.")

                if credentialSetID == nil {
                    TextField("Username", text: $username)

                    Picker("Auth", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { Text($0.displayName).tag($0) }
                    }

                    switch authMethod {
                    case .password:
                        SecureField(isEditing ? "Password (leave blank to keep current)" : "Password", text: $secret)
                    case .privateKey:
                        TextField("Private key path", text: $privateKeyPath)
                        Text("OpenSSH-format RSA or Ed25519 keys only (\"-----BEGIN OPENSSH PRIVATE KEY-----\"). Encrypted keys work too — enter the passphrase below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField(isEditing ? "Key passphrase (leave blank to keep current)" : "Key passphrase (leave blank if the key isn't encrypted)", text: $secret)
                    case .agent:
                        Text("Uses keys already loaded in ssh-agent.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Logs in as \"\(credentialSetStore.credentialSets.first(where: { $0.id == credentialSetID })?.username ?? "")\" from the credential set above, instead of this profile's own username/password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Manage Credential Sets…") {
                    showingCredentialSets = true
                }
                .buttonStyle(.link)

                HStack {
                    Text("Keepalive")
                    TextField("30", text: $keepaliveInterval)
                        .frame(width: 50)
                    Text("sec (0 = off)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help("Sends a harmless keystroke once the session has been idle this long, so the device's own idle timeout doesn't drop the connection. Some hardened environments log this as activity — set to 0 there.")

                Toggle("Auto-reconnect", isOn: $autoReconnect)
                    .help("Automatically retry every 15s (up to 20 attempts) if this session disconnects. Off by default — retrying into a device mid-reboot can catch it half-booted.")
            }

            if kind == .telnet {
                Text("Telnet sends everything — including passwords — in plain text. Only use it for legacy gear that doesn't support SSH.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if kind == .serial {
                HStack {
                    Picker("Serial Port", selection: $serialPortPath) {
                        if availableSerialPorts.isEmpty {
                            Text("No serial ports found").tag("")
                        }
                        ForEach(availableSerialPorts) { port in
                            Text(port.name).tag(port.path)
                        }
                    }
                    Button {
                        refreshSerialPorts()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh the list of connected serial adapters.")
                }

                Picker("Baud Rate", selection: $baudRate) {
                    ForEach([1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200], id: \.self) { rate in
                        Text("\(rate)").tag(rate)
                    }
                }
                Text("9600 is the standard console speed for most Cisco, Palo Alto, Fortinet, and Aruba gear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Theme", selection: $themeID) {
                ForEach(TerminalTheme.all) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }

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
        .onAppear {
            if kind == .serial { refreshSerialPorts() }
            populateGroupFieldsIfNeeded()
        }
        .sheet(isPresented: $showingCredentialSets) {
            CredentialSetsView()
        }
        .onChange(of: kind) { oldValue, newValue in
            if newValue == .serial {
                refreshSerialPorts()
            }
            if newValue == .telnet, port == "22" {
                port = "23"
            } else if newValue == .ssh, port == "23" {
                port = "22"
            }
        }
    }

    /// Icon-button row from the UI spec: SSH and Local are real, one-tap
    /// protocol choices; Serial and RDP are shown but visually disabled —
    /// a deliberate roadmap hint (Serial is actually implemented already,
    /// reachable via the "Type" picker below; RDP is Phase 6 and doesn't
    /// exist as a SessionKind yet at all), not an oversight.
    private var protocolPickerRow: some View {
        HStack(spacing: 10) {
            protocolButton(label: "SSH", systemImage: "terminal", enabled: true) {
                kind = .ssh
            }
            protocolButton(label: "Local", systemImage: "desktopcomputer", enabled: true) {
                kind = .local
            }
            protocolButton(label: "Serial", systemImage: "cable.connector.horizontal", enabled: false) {}
            protocolButton(label: "RDP", systemImage: "display", enabled: false) {}
            Spacer()
        }
    }

    private func protocolButton(label: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 16))
                Text(label).font(.caption2)
            }
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.4)
        .help(enabled ? "Use \(label)" : "\(label) is coming in a later phase.")
    }

    /// Resolves a previously-saved profile's group back into Customer/Device
    /// Type field text. Can't run this in `init` — ProfileStore is an
    /// `@EnvironmentObject`, not available until the view is in the
    /// hierarchy — so it happens on first appearance instead.
    private func populateGroupFieldsIfNeeded() {
        guard customer.isEmpty, let groupID = editingGroupID else { return }
        guard let deviceGroup = profileStore.groups.first(where: { $0.id == groupID }) else { return }
        if let parentID = deviceGroup.parentID,
           let customerGroup = profileStore.groups.first(where: { $0.id == parentID }) {
            customer = customerGroup.name
        }
        if let matched = DeviceTypeOption.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(deviceGroup.name) == .orderedSame
        }) {
            deviceType = matched
        }
    }

    private func refreshSerialPorts() {
        availableSerialPorts = SerialPortLister.availablePorts()
        if serialPortPath.isEmpty, let first = availableSerialPorts.first {
            serialPortPath = first.path
        }
    }

    private func save() {
        let trimmedCustomer = customer.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedGroupID: UUID? = trimmedCustomer.isEmpty
            ? editingGroupID
            : profileStore.findOrCreateGroup(customer: trimmedCustomer, deviceType: deviceType.rawValue)

        var profile = SessionProfile(
            id: editingID ?? UUID(),
            name: name,
            kind: kind,
            themeID: themeID,
            groupID: resolvedGroupID,
            lastConnectedAt: editingLastConnectedAt
        )
        switch kind {
        case .ssh:
            profile.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.port = Int(port) ?? 22
            profile.username = username
            profile.authMethod = authMethod
            profile.privateKeyPath = authMethod == .privateKey ? privateKeyPath : nil
            profile.keepaliveInterval = Int(keepaliveInterval) ?? 30
            profile.autoReconnect = autoReconnect
            profile.credentialSetID = credentialSetID
        case .telnet:
            profile.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.port = Int(port) ?? 23
        case .serial:
            profile.serialPortPath = serialPortPath
            profile.baudRate = baudRate
        case .local:
            break
        }
        profileStore.upsert(profile, secret: kind == .ssh ? secret : nil)
        dismiss()
    }
}
