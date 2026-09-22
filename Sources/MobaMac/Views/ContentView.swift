import SwiftUI

struct ContentView: View {
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var credentialSetStore: CredentialSetStore
    @State private var showingNewSession = false
    @State private var editingProfile: SessionProfile?
    @State private var showingSFTP = false
    @State private var showingNetworkTools = false
    @State private var showingSnippets = false
    @State private var showingQuickConnect = false
    @State private var showingLogViewer = false
    @State private var showingBroadcastPopover = false

    var body: some View {
        NavigationSplitView {
            SidebarView(showingNewSession: $showingNewSession, editingProfile: $editingProfile)
        } detail: {
            VStack(spacing: 0) {
                if !sessionManager.broadcastTargetIDs.isEmpty {
                    broadcastBanner
                }

                if sessionManager.openSessions.isEmpty {
                    emptyState
                } else {
                    TabView(selection: $sessionManager.activeSessionID) {
                        ForEach(sessionManager.openSessions) { session in
                            SessionTabView(session: session)
                                .tag(Optional(session.id))
                                .tabItem { Text(session.title) }
                        }
                    }
                }
            }
        }
        // SessionManager needs a way back to ProfileStore to stamp
        // `lastConnectedAt` when a connection succeeds (UI spec §1's
        // "Recent" section reads that field) — wired here once, harmless to
        // repeat on every appearance.
        .onAppear {
            sessionManager.profileStore = profileStore
            sessionManager.credentialSetStore = credentialSetStore
        }
        .sheet(isPresented: $showingNewSession) {
            NewSessionSheet()
        }
        .sheet(item: $editingProfile) { profile in
            NewSessionSheet(profileToEdit: profile)
        }
        .sheet(isPresented: $showingSFTP) {
            if case .ssh(let ssh)? = sessionManager.activeSession?.kind {
                SFTPBrowserView(ssh: ssh)
            }
        }
        .sheet(isPresented: $showingNetworkTools) {
            NetworkToolsView()
        }
        .sheet(isPresented: $showingSnippets) {
            SnippetsPanelView()
        }
        .sheet(isPresented: $showingQuickConnect) {
            QuickConnectSheet()
        }
        .sheet(isPresented: $showingLogViewer) {
            LogViewerView()
        }
        .sheet(isPresented: $sessionManager.showingCommandPalette) {
            CommandPaletteView()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingQuickConnect = true
                } label: {
                    Label("Quick Connect", systemImage: "bolt")
                }
                .help("Connect to a host right now without saving a session profile.")

                Button {
                    showingSnippets = true
                } label: {
                    Label("Snippets", systemImage: "text.badge.plus")
                }
                .help("Saved commands you can fire into the active session with one click.")

                Button {
                    showingLogViewer = true
                } label: {
                    Label("Logs", systemImage: "doc.text.magnifyingglass")
                }
                .help("Browse per-session log files.")

                Button {
                    showingNetworkTools = true
                } label: {
                    Label("Network Tools", systemImage: "network")
                }
                .help("Ping, traceroute, DNS lookup, port scan, subnet calculator.")

                Button {
                    showingSFTP = true
                } label: {
                    Label("SFTP", systemImage: "folder.badge.gearshape")
                }
                .help("Browse files on the active SSH session.")
                .disabled(activeSSHSession == nil)

                highlightToggleItem

                themeMenuItem

                Button {
                    openBroadcastPopover()
                } label: {
                    Label(
                        "Broadcast (\(sessionManager.broadcastTargetIDs.count))",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                }
                .popover(isPresented: $showingBroadcastPopover) {
                    BroadcastPopoverView()
                }
                .help("Choose which open SSH tabs share keystrokes with each other (multi-exec).")
                .tint(sessionManager.broadcastTargetIDs.isEmpty ? nil : .red)

                Button {
                    sessionManager.closeActive()
                } label: {
                    Label("Close Tab", systemImage: "xmark.circle")
                }
                .help("Close the active session and its log file (⌘W).")
                .keyboardShortcut("w", modifiers: .command)
                .disabled(sessionManager.activeSession == nil)
            }
        }
    }

    private var activeSSHSession: SSHConnectionSession? {
        if case .ssh(let ssh)? = sessionManager.activeSession?.kind {
            return ssh
        }
        return nil
    }

    /// Only meaningful for SSH tabs — Telnet/Serial/Local never route through
    /// the highlighting pipeline (see SSHTerminalHostView), so the button is
    /// disabled rather than silently doing nothing for other session kinds.
    @ViewBuilder
    private var highlightToggleItem: some View {
        if activeSSHSession != nil, let session = sessionManager.activeSession {
            HighlightToggleButton(session: session)
        } else {
            Button {} label: {
                Label("Highlight", systemImage: "highlighter")
            }
            .disabled(true)
        }
    }

    /// Live per-tab color-theme picker, requested as a follow-up to the
    /// Theme field already in New/Edit Session: that field only decides what
    /// a *freshly opened* tab starts with, so it can't restyle a session
    /// you're already connected to. This toolbar menu is the "change it on
    /// the session I'm looking at right now" path instead — it edits
    /// `OpenSession.themeID` directly, which `SessionTabView`'s `onChange`
    /// below immediately repaints the live `TerminalView` from.
    @ViewBuilder
    private var themeMenuItem: some View {
        Menu {
            ForEach(TerminalTheme.all) { theme in
                Button {
                    setTheme(theme.id)
                } label: {
                    if sessionManager.activeSession?.themeID == theme.id {
                        Label(theme.name, systemImage: "checkmark")
                    } else {
                        Text(theme.name)
                    }
                }
            }
            Divider()
            // UI spec: theme defaults — promotes whatever the active tab is
            // currently showing to be what brand-new session profiles start
            // on, instead of leaving that stuck at the hardcoded
            // "Default (Terminal.app)" forever.
            Button("Set as Default for New Sessions") {
                if let themeID = sessionManager.activeSession?.themeID {
                    TerminalTheme.appDefaultID = themeID
                }
            }
        } label: {
            Label("Theme", systemImage: "paintpalette")
        }
        .help("Change the color theme of the active session.")
        .disabled(sessionManager.activeSession == nil)
    }

    /// Applies a theme to the active tab's already-running terminal (via the
    /// `themeID` published property `SessionTabView` observes) and also
    /// writes it back to that tab's saved profile, so the choice sticks: the
    /// *next* tab opened from this profile starts on the same theme instead
    /// of reverting to whatever it was saved with before. `secret: nil` is
    /// safe here — `ProfileStore.upsert` only touches the Keychain entry
    /// when a non-nil secret is passed, so this can't clobber a saved
    /// password/passphrase.
    private func setTheme(_ id: String) {
        guard let session = sessionManager.activeSession else { return }
        session.themeID = id
        var updated = session.profile
        updated.themeID = id
        profileStore.upsert(updated, secret: nil)
    }

    /// Seeds the default-checked set the first time broadcast is turned on
    /// (UI spec §3): only sessions under the same top-level customer as the
    /// currently active tab get auto-checked. If targets are already set —
    /// broadcast is already "on" — reopening the popover leaves the existing
    /// selection alone instead of resetting it.
    private func openBroadcastPopover() {
        if sessionManager.broadcastTargetIDs.isEmpty {
            let activeCustomerID = profileStore.topLevelCustomerID(for: sessionManager.activeSession?.profile.groupID)
            if let activeCustomerID {
                let matching = sessionManager.openSSHSessions.filter {
                    profileStore.topLevelCustomerID(for: $0.profile.groupID) == activeCustomerID
                }
                sessionManager.broadcastTargetIDs = Set(matching.map(\.id))
            }
        }
        showingBroadcastPopover = true
    }

    private var broadcastBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text(broadcastBannerText)
                .font(.caption).bold()
            Spacer()
        }
        .padding(6)
        .background(Color.red.opacity(0.25))
    }

    private var broadcastBannerText: String {
        let count = sessionManager.broadcastTargetIDs.count
        return "Broadcast is ON. Keystrokes are shared across \(count) opted-in SSH tab\(count == 1 ? "" : "s")."
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No session open")
                .font(.headline)
            Text("Pick a profile from the sidebar, or add a new one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Backs the toolbar's Highlight toggle. Needs `@ObservedObject` (not just a
/// plain closure reading `session.highlightingEnabled`) so SwiftUI actually
/// redraws the button when that `@Published` flag flips — the same reason
/// SessionTabView below observes `session` directly for `connectionIssue`.
private struct HighlightToggleButton: View {
    @ObservedObject var session: OpenSession

    var body: some View {
        Button {
            session.highlightingEnabled.toggle()
        } label: {
            Label("Highlight", systemImage: "highlighter")
        }
        .tint(session.highlightingEnabled ? .yellow : nil)
        .help("Buffers output per line to highlight IPs, MAC addresses, and status/errors. Adds latency (including your own typed echo) until Enter is pressed, which is why it's off by default per session.")
    }
}

/// One tab's content. A dedicated view (rather than a `@ViewBuilder` helper
/// function on ContentView) so SwiftUI actually observes `session`'s
/// `@Published connectionIssue` — a plain function called from inside
/// ContentView's body wouldn't re-run just because a nested object's
/// published property changed, only `@ObservedObject` gets that for free.
private struct SessionTabView: View {
    @ObservedObject var session: OpenSession
    @EnvironmentObject var sessionManager: SessionManager
    @State private var promptPassword = ""
    @State private var promptSavePassword = false

    var body: some View {
        Group {
            if let issue = session.connectionIssue {
                connectionIssueView(issue)
            } else {
                switch session.kind {
                case .ssh(let ssh):
                    SSHTerminalHostView(openSession: session, ssh: ssh)
                case .ssh1(let ssh1):
                    RawTerminalHostView(openSession: session, connection: ssh1)
                case .telnet(let telnet):
                    RawTerminalHostView(openSession: session, connection: telnet)
                case .serial(let serial):
                    RawTerminalHostView(openSession: session, connection: serial)
                case .local:
                    LocalTerminalHostView(openSession: session)
                }
            }
        }
        // The toolbar's live theme picker changes `session.themeID` (a plain
        // `@Published` property the view tree doesn't otherwise read to
        // decide what to draw), so nothing above would notice the change on
        // its own — the host views only read `themeID` once, at
        // `makeNSView` time. This is what actually pushes a picked theme
        // onto the already-running SwiftTerm.TerminalView.
        .onChange(of: session.themeID) { _, newValue in
            session.terminalView?.apply(theme: TerminalTheme.theme(for: newValue))
        }
    }

    private func issueTitle(_ issue: SSHConnectionIssue) -> String {
        if issue.needsPassword { return "Password required" }
        if issue.isHostKeyMismatch { return "Host key changed" }
        if issue.isSessionEnded { return "Session ended" }
        return issue.isDisconnection ? "Disconnected" : "Connection failed"
    }

    private func issueSymbol(_ issue: SSHConnectionIssue) -> String {
        if issue.needsPassword { return "key.fill" }
        if issue.isHostKeyMismatch { return "exclamationmark.triangle.fill" }
        if issue.isSessionEnded { return "checkmark.circle" }
        return "xmark.octagon"
    }

    private func issueColor(_ issue: SSHConnectionIssue) -> Color {
        if issue.isHostKeyMismatch { return .yellow }
        if issue.needsPassword || issue.isSessionEnded { return .secondary }
        return .red
    }

    private func submitPassword() {
        guard !promptPassword.isEmpty else { return }
        let password = promptPassword
        promptPassword = ""
        sessionManager.submitPassword(password, for: session, save: promptSavePassword)
    }

    private func connectionIssueView(_ issue: SSHConnectionIssue) -> some View {
        VStack(spacing: 12) {
            Image(systemName: issueSymbol(issue))
                .font(.system(size: 36))
                .foregroundStyle(issueColor(issue))
            Text(issueTitle(issue))
                .font(.headline)
            Text(issue.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if session.reconnectAttempt > 0 {
                Text("Reconnecting… \(session.reconnectAttempt)/\(SessionManager.maxAutoReconnectAttempts)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if issue.needsPassword {
                SecureField("Password", text: $promptPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(submitPassword)
                Toggle("Save password", isOn: $promptSavePassword)
            }
            HStack {
                if issue.needsPassword {
                    Button("Connect", action: submitPassword)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(promptPassword.isEmpty)
                } else if issue.isHostKeyMismatch {
                    Button("Trust New Key & Reconnect") {
                        sessionManager.retryTrustingHostKey(session)
                    }
                    .buttonStyle(.borderedProminent)
                } else if issue.isDisconnection || issue.isSessionEnded {
                    Button("Reconnect") {
                        sessionManager.reconnect(session)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Reconnect this session (⌘R).")
                } else {
                    // A connection that never came up at all still deserves a
                    // retry: plenty of these are transient (the device was
                    // out of SSH sessions, the handshake timed out, the link
                    // was briefly down), and the alternative is closing the
                    // tab and walking back through the sidebar and its
                    // confirmation dialog to try the same thing again.
                    Button("Try Again") {
                        sessionManager.reconnect(session)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Try this connection again (⌘R).")
                }
                Button("Close Tab") {
                    sessionManager.close(session)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
