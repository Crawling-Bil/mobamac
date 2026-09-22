import SwiftUI

/// A one-off connection that never touches ProfileStore — for "SSH into
/// something once, right now" where saving a permanent profile is overkill.
/// Builds a throwaway SessionProfile in memory and hands it straight to
/// SessionManager exactly like a saved profile would be, minus persistence.
struct QuickConnectSheet: View {
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var kind: SessionKind = .ssh
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    /// Off by default: Quick Connect is for one-off connections, and a
    /// password shouldn't end up in the Keychain unless the user asks.
    @State private var savePassword = false

    private var hostError: String? { HostValidator.hostErrorMessage(for: host) }
    private var portError: String? { HostValidator.portErrorMessage(for: port) }
    private var isValid: Bool {
        HostValidator.isValidHost(host) && HostValidator.isValidPort(port)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Connect").font(.title2.bold())
            Text("Connects immediately without saving a session profile.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Type", selection: $kind) {
                Text(SessionKind.ssh.displayName).tag(SessionKind.ssh)
                Text(SessionKind.telnet.displayName).tag(SessionKind.telnet)
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { oldValue, newValue in
                if newValue == .telnet, port == "22" {
                    port = "23"
                } else if newValue == .ssh, port == "23" {
                    port = "22"
                }
            }

            TextField("Host", text: $host)
            if let hostError {
                Text(hostError).font(.caption).foregroundStyle(.red)
            }
            TextField("Port", text: $port)
            if let portError {
                Text(portError).font(.caption).foregroundStyle(.red)
            }

            if kind == .ssh {
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                Toggle("Save password", isOn: $savePassword)
                    .help("Store the password in the Keychain once it works, so reconnecting from Recent doesn't ask again.")
            } else {
                Text("Telnet sends everything, passwords included, in plain text.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func connect() {
        var profile = SessionProfile(name: "\(host):\(port)", kind: kind)
        profile.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.port = Int(port) ?? (kind == .telnet ? 23 : 22)
        switch kind {
        case .ssh:
            profile.username = username
            profile.authMethod = .password
            sessionManager.openSSH(profile: profile, secret: password.isEmpty ? nil : password, saveSecret: savePassword)
        case .telnet:
            sessionManager.openTelnet(profile: profile)
        case .serial, .local:
            break
        }
        dismiss()
    }
}
