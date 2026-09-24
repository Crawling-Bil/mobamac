import SwiftUI

/// Fixed, extendable device-type list for the New Session form's Device
/// Type dropdown (UI spec §5). Add cases here as new device types come up:
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

/// An unsaved copy of a session on its way to the Duplicate sheet. Carries
/// the secret separately because passwords live in the Keychain under the
/// profile's id, and this copy's id doesn't exist there yet.
struct SessionDraft: Identifiable {
    let id = UUID()
    let profile: SessionProfile
    let secret: String?
    /// Shown under the password field when the original's password could
    /// not be read back, so an empty field is explained rather than
    /// discovered later as a failed login.
    let notice: String?
}

/// Also doubles as the "Edit Session" and "Duplicate Session" sheets: pass
/// `profileToEdit` to pre-fill the form and save under that profile's id
/// instead of creating a new one. A duplicate arrives the same way, already
/// carrying a fresh id, so saving creates it and cancelling leaves nothing
/// behind.
struct NewSessionSheet: View {
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var credentialSetStore: CredentialSetStore
    @Environment(\.dismiss) private var dismiss

    private let editingID: UUID?
    private let editingGroupID: UUID?
    private let editingLastConnectedAt: Date?
    private let isDuplicate: Bool
    private let secretNotice: String?

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
    @State private var startupCommands: String
    @State private var promptPattern: String
    @State private var showingCredentialSets = false

    init(
        profileToEdit: SessionProfile? = nil,
        duplicating: Bool = false,
        prefilledSecret: String? = nil,
        secretNotice: String? = nil
    ) {
        isDuplicate = duplicating
        self.secretNotice = secretNotice
        _secret = State(initialValue: prefilledSecret ?? "")
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
        _startupCommands = State(initialValue: profileToEdit?.startupCommands ?? "")
        _promptPattern = State(initialValue: profileToEdit?.promptPattern ?? "")
    }

    /// True only for a real edit. A duplicate also arrives with an id, but
    /// that id has never been saved, so the form should read and behave as
    /// if it were new — "leave blank to keep current" would be a lie when
    /// there is no current password to keep.
    private var isEditing: Bool { editingID != nil && !isDuplicate }

    private var title: String {
        if isDuplicate { return "Duplicate Session" }
        return isEditing ? "Edit Session" : "New Session"
    }

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
            Text(title).font(.title2.bold())

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
                .help("Use a saved credential set instead of entering credentials below. Changes to the set apply to every session that uses it.")

                if credentialSetID == nil {
                    TextField("Username", text: $username)

                    Picker("Auth", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { Text($0.displayName).tag($0) }
                    }

                    switch authMethod {
                    case .password:
                        SecureField(isEditing ? "Password (leave blank to keep current)" : "Password", text: $secret)
                        if let secretNotice {
                            Text(secretNotice)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    case .privateKey:
                        TextField("Private key path", text: $privateKeyPath)
                        Text("OpenSSH-format RSA or Ed25519 keys only (\"-----BEGIN OPENSSH PRIVATE KEY-----\"). Encrypted keys work too. Enter the passphrase below.")
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
                .help("Sends a keepalive after this many seconds of inactivity so the device's idle timeout doesn't close the session. Set to 0 to disable, for example where keepalives are logged as user activity.")

                Toggle("Auto-reconnect", isOn: $autoReconnect)
                    .help("Retries every 15 seconds, up to 20 attempts, if the session disconnects. Off by default, because reconnecting during a reboot can reach the device before it has fully started.")
            }

            if kind != .local {
                startupCommandsSection
            }

            if kind == .telnet {
                Text("Telnet sends all data, including passwords, unencrypted. Use it only for legacy devices that don't support SSH.")
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
                Text("Most Cisco, Palo Alto, and Fortinet consoles use 9600. Aruba CX switches use 115200.")
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
    /// reachable via the "Type" picker below; RDP is not implemented and doesn't
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
        .help(enabled ? "Use \(label)" : "\(label) is not available yet.")
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

    /// One command per line. Disabling paging is what almost everyone puts
    /// here, and it has to be re-sent on every connect, so it belongs on the
    /// profile rather than being typed each time.
    @ViewBuilder
    private var startupCommandsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Startup commands")
                .font(.callout)
            TextEditor(text: $startupCommands)
                .font(.system(.body, design: .monospaced))
                .frame(height: 56)
                .border(Color.secondary.opacity(0.3))
            Text("Sent one line at a time after the device is ready.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Wait for prompt pattern (optional)", text: $promptPattern)
                .font(.system(.body, design: .monospaced))
                .help("A regular expression matching this device's prompt. When set, commands are sent as soon as the output matches, instead of waiting for the output to go quiet.")
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
            profile.startupCommands = startupCommands.isEmpty ? nil : startupCommands
            profile.promptPattern = promptPattern.isEmpty ? nil : promptPattern
        case .telnet:
            profile.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.port = Int(port) ?? 23
            profile.startupCommands = startupCommands.isEmpty ? nil : startupCommands
            profile.promptPattern = promptPattern.isEmpty ? nil : promptPattern
        case .serial:
            profile.serialPortPath = serialPortPath
            profile.baudRate = baudRate
            profile.startupCommands = startupCommands.isEmpty ? nil : startupCommands
            profile.promptPattern = promptPattern.isEmpty ? nil : promptPattern
        case .local:
            break
        }
        profileStore.upsert(profile, secret: kind == .ssh ? secret : nil)
        dismiss()
    }
}
