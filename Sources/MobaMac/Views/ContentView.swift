import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var credentialSetStore: CredentialSetStore
    @State private var showingNewSession = false
    @State private var editingProfile: SessionProfile?
    @State private var showingSFTP = false
    @State private var showingSnippets = false
    @State private var showingQuickConnect = false
    @State private var showingLogViewer = false
    @State private var showingBroadcastPopover = false
    /// Which right-hand panel is open, if any. One slot on purpose: two
    /// panels side by side would leave the terminal with nothing.
    @State private var activePanel: DetailPanel?
    @State private var panelMinimized = false
    /// Owned here rather than by the panel, so its results outlive every
    /// open/close of the panel. See NetworkToolsModel.
    @StateObject private var networkTools = NetworkToolsModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(showingNewSession: $showingNewSession, editingProfile: $editingProfile)
        } detail: {
            detailColumn
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
        // `toolbar(id:)` rather than a plain `toolbar` so the items below are
        // real, customizable toolbar items: View ▸ Customize Toolbar lets
        // someone drag out what they never use and add back what they do.
        // That only works if every item carries a stable id, which is also
        // what lets macOS remember the arrangement across launches.
        .toolbar(id: "main") {
            ToolbarItem(id: "quickConnect", placement: .automatic) {
                Button {
                    showingQuickConnect = true
                } label: {
                    Label("Quick Connect", systemImage: "bolt")
                }
                .help("Connect to a host right now without saving a session profile.")
            }

            ToolbarItem(id: "panels", placement: .automatic) {
                panelsMenu
            }

            ToolbarItem(id: "session", placement: .automatic) {
                sessionMenu
            }

            ToolbarItem(id: "broadcast", placement: .automatic) {
                broadcastButton
            }
        }
    }

    /// The detail column: the tab strip, the terminal beside whatever panel
    /// is open, and the status bar, as three plain rows of one VStack.
    ///
    /// The status bar used to be a `safeAreaInset`, which was wrong in a way
    /// that only showed up in use: an NSViewRepresentable doesn't honour the
    /// safe area, so SwiftTerm kept sizing itself to the full height and the
    /// bar sat on top of its bottom row. The prompt was there, just
    /// underneath. Worse, SwiftTerm derived its row count from that same
    /// full height and reported it to the device through
    /// `resize(cols:rows:)`, so the device believed the screen was one row
    /// taller than it was and paged long output like "show running-config"
    /// against the wrong height.
    ///
    /// A VStack row takes the height away for real, so SwiftTerm recomputes
    /// its rows and tells the device the truth. Nothing may overlap the
    /// terminal.
    private var detailColumn: some View {
        VStack(spacing: 0) {
            if !sessionManager.openSessions.isEmpty {
                SessionTabBar()
            }
            HSplitView {
                sessionArea
                if let panel = activePanel {
                    panelColumn(panel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let session = sessionManager.activeSession {
                StatusBarView(session: session)
            }
        }
        // The window title follows the active tab, so a row of MobaMac
        // windows in Mission Control or the Window menu is readable instead
        // of four identical "MobaMac" entries. The subtitle is a separate
        // string on purpose: macOS draws it in its own smaller style, which
        // is better than gluing the host onto the name with a dash.
        .navigationTitle(sessionManager.activeSession?.title ?? "MobaMac")
        .navigationSubtitle(windowSubtitle)
    }

    /// Every open tab is built and kept in the hierarchy, with the inactive
    /// ones faded out rather than removed. That is not decoration: each tab's
    /// terminal is an AppKit `NSView` owning its own scrollback, so dropping
    /// it from the view tree on a tab switch would throw away everything the
    /// session has printed. `TabView` did this for us; drawing the tab strip
    /// by hand means doing it here.
    private var sessionArea: some View {
        Group {
            if sessionManager.openSessions.isEmpty {
                emptyState
            } else {
                ZStack {
                    ForEach(sessionManager.openSessions) { session in
                        let isActive = session.id == sessionManager.activeSessionID
                        SessionTabView(session: session)
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                            .zIndex(isActive ? 1 : 0)
                    }
                }
            }
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        // Keyboard focus does not follow opacity: without this, switching
        // tabs leaves the first responder on the terminal that just became
        // invisible, and typing goes into a tab nobody can see.
        .onChange(of: sessionManager.activeSessionID) { _, newValue in
            guard let session = sessionManager.openSessions.first(where: { $0.id == newValue }) else { return }
            sessionManager.focusTerminal(of: session)
        }
    }

    @ViewBuilder
    private func panelColumn(_ panel: DetailPanel) -> some View {
        SidePanelContainer(
            title: panel.title,
            icon: panel.icon,
            isMinimized: $panelMinimized,
            onClose: { activePanel = nil }
        ) {
            switch panel {
            case .networkTools:
                NetworkToolsView()
                    .environmentObject(networkTools)
            }
        }
    }

    /// Clicking the toolbar button for the panel that is already open closes
    /// it, which is what a toggle in a toolbar is expected to do. Opening a
    /// panel always un-minimizes: asking for a panel and getting a 32pt
    /// strip would read as the button not working.
    private func toggle(_ panel: DetailPanel) {
        if activePanel == panel {
            activePanel = nil
        } else {
            activePanel = panel
            panelMinimized = false
        }
    }

    private var windowSubtitle: String {
        guard let session = sessionManager.activeSession else { return "" }
        switch session.profile.kind {
        case .local:
            return "Local Terminal"
        case .serial:
            let path = session.profile.serialPortPath ?? ""
            return path.isEmpty ? "Serial" : (path as NSString).lastPathComponent
        case .ssh, .telnet:
            let hostPort = "\(session.profile.host):\(session.profile.port)"
            let user = session.profile.username
            return user.isEmpty ? hostPort : "\(user)@\(hostPort)"
        }
    }

    // MARK: - Toolbar

    /// Everything that opens an auxiliary view. Grouped because five separate
    /// buttons were the first things to fall off the end of the toolbar on a
    /// narrow window — which is exactly how "Add Folder" became invisible for
    /// new users in 1.7.
    private var panelsMenu: some View {
        Menu {
            Button {
                showingSFTP = true
            } label: {
                Label("SFTP", systemImage: "folder.badge.gearshape")
            }
            .disabled(activeSSHSession == nil)

            Button {
                showingSnippets = true
            } label: {
                Label("Snippets", systemImage: "text.badge.plus")
            }

            Button {
                showingLogViewer = true
            } label: {
                Label("Logs", systemImage: "doc.text.magnifyingglass")
            }

            Button {
                toggle(.networkTools)
            } label: {
                Label("Network Tools", systemImage: "network")
            }
        } label: {
            Label("Panels", systemImage: "sidebar.squares.right")
        }
        .help("SFTP, snippets, logs, and network tools.")
    }

    /// Actions that apply to the tab you are looking at right now.
    private var sessionMenu: some View {
        Menu {
            highlightToggleItem
            themeMenuItem
            Divider()
            Button {
                sessionManager.requestCloseActive()
            } label: {
                Label("Close Tab", systemImage: "xmark.circle")
            }
            .disabled(sessionManager.activeSession == nil)
            .help("Close the active session and its log file (⌘W).")
        } label: {
            Label("Session", systemImage: "slider.horizontal.3")
        }
        .help("Highlighting, theme, and closing the active tab.")
        .disabled(sessionManager.activeSession == nil)
    }

    private var broadcastButton: some View {
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
    }

    private var activeSSHSession: SSHConnectionSession? {
        if case .ssh(let ssh)? = sessionManager.activeSession?.kind {
            return ssh
        }
        return nil
    }

    /// Only meaningful for SSH tabs — Telnet/Serial/Local never route through
    /// the highlighting pipeline (see SSHTerminalHostView), so the toggle is
    /// disabled rather than silently doing nothing for other session kinds.
    @ViewBuilder
    private var highlightToggleItem: some View {
        if activeSSHSession != nil, let session = sessionManager.activeSession {
            HighlightToggleButton(session: session)
        } else {
            Toggle("Highlight Output", isOn: .constant(false))
                .disabled(true)
        }
    }

    /// Live per-tab color-theme picker, requested as a follow-up to the
    /// Theme field already in New/Edit Session: that field only decides what
    /// a *freshly opened* tab starts with, so it can't restyle a session
    /// you're already connected to. This menu is the "change it on the
    /// session I'm looking at right now" path instead — it edits
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

/// Backs the Session menu's Highlight toggle. Needs `@ObservedObject` (not
/// just a plain closure reading `session.highlightingEnabled`) so SwiftUI
/// actually redraws the checkmark when that `@Published` flag flips — the
/// same reason SessionTabView below observes `session` directly for
/// `connectionIssue`.
private struct HighlightToggleButton: View {
    @ObservedObject var session: OpenSession

    var body: some View {
        Toggle("Highlight Output", isOn: $session.highlightingEnabled)
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
                    sessionManager.requestClose(session)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
