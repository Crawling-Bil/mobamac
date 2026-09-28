import SwiftUI

/// Small colored dot showing a profile's live connection state (UI spec §2):
/// gray outline = idle/saved-not-connected, yellow = connecting,
/// green = connected, red = failed. Resets to idle as soon as its tab
/// closes — see `SessionManager.close(_:)`. Each case gets its own `.help()`
/// (UI spec §8) since the color coding otherwise only exists in a one-time
/// legend nobody reliably remembers.
private struct StatusDot: View {
    let state: SessionManager.ConnectionState

    var body: some View {
        ConnectionDot(state: state)
            .help(helpText)
    }

    private var helpText: String {
        switch state {
        case .idle: return "Not connected."
        case .connecting: return "Connecting…"
        case .connected: return "Connected."
        case .failed: return "Last connection attempt failed."
        }
    }
}

/// Sidebar restructured per the UI spec: a "Recent" section (top 3 by
/// `lastConnectedAt`), then a Customer → Device Type → Device tree built
/// from `ProfileStore.groups`'s existing `parentID` nesting. Search
/// collapses the tree into a flat, breadcrumbed list instead — easier to
/// scan a handful of matches than to hunt through several expanded
/// disclosure levels.
struct SidebarView: View {
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var sessionManager: SessionManager
    @Binding var showingNewSession: Bool
    @Binding var editingProfile: SessionProfile?
    @Binding var duplicatingSession: SessionDraft?

    /// Set when a row is tapped; opening only actually happens once the
    /// user confirms in the dialog below. Requested explicitly: opening
    /// straight into a new terminal tab with no confirmation made it too
    /// easy to fire off multiple connections by accident.
    @State private var pendingProfile: SessionProfile?
    @State private var profileToDelete: SessionProfile?
    @State private var searchText = ""
    /// One piece of state for both sidebar sheets, rather than a
    /// `@State` flag and a `.sheet(isPresented:)` per sheet. Stacking two
    /// `.sheet` modifiers on the same view is a long-standing way to end up
    /// with one of them silently never presenting, and "New Folder does
    /// nothing" is exactly that symptom.
    @State private var activeSheet: SidebarSheet?

    private enum SidebarSheet: Identifiable {
        case newFolder(presetCustomer: String?)
        case manageFolders

        var id: String {
            switch self {
            case .newFolder(let preset):
                return "newFolder:\(preset ?? "")"
            case .manageFolders:
                return "manageFolders"
            }
        }
    }
    @State private var groupPendingDelete: SessionGroup?
    /// Which Customer/Device-Type folders are expanded. Manual instead of
    /// `DisclosureGroup`'s built-in toggle because putting the "…" actions
    /// menu inside a `DisclosureGroup` label made its hit area unreliable —
    /// clicks sometimes landed on the disclosure's own expand/collapse
    /// gesture instead of the menu button sitting right next to it. Two
    /// separate `Button`/`Menu` controls side by side in a plain `HStack`
    /// don't have that ambiguity.
    /// The row under the pointer, whose actions button is showing. One
    /// value for the whole sidebar since only one row can be hovered at a
    /// time. It is a string rather than the row's UUID because the same
    /// session can be on screen twice, under Recent and in its folder, and
    /// hovering one copy must not light up the other.
    @State private var hoveredRowKey: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedCustomers: Set<UUID> = []
    @State private var expandedDeviceTypes: Set<UUID> = []

    private var isSearching: Bool { !searchText.isEmpty }

    private var filteredProfiles: [SessionProfile] {
        guard isSearching else { return profileStore.profiles }
        return profileStore.profiles.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.host.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var recentProfiles: [SessionProfile] {
        profileStore.profiles
            .filter { $0.lastConnectedAt != nil }
            .sorted { $0.lastConnectedAt! > $1.lastConnectedAt! }
            .prefix(3)
            .map { $0 }
    }

    /// Profiles whose `groupID` doesn't resolve to a real device-type group
    /// — either never grouped, or pointing at a group that's since been
    /// removed. Shown in their own section so nothing saved before this
    /// feature existed just silently disappears from the sidebar.
    private var ungroupedProfiles: [SessionProfile] {
        let deviceTypeIDs = Set(profileStore.groups.filter { $0.parentID != nil }.map(\.id))
        return profileStore.profiles
            .filter { profile in
                guard let groupID = profile.groupID else { return true }
                return !deviceTypeIDs.contains(groupID)
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            if !isSearching && !recentProfiles.isEmpty {
                recentSection
            }

            if isSearching {
                searchResultsSection
            } else {
                groupedSessionsSection
            }
        }
        // A known range for the column, so the split view never gives the
        // sidebar less width than its rows are laid out for.
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 420)
        .searchable(text: $searchText, prompt: "Search sessions")
        .help("Search saved sessions by name or host.")
        .toolbar { toolbarContent }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .newFolder(let presetCustomer):
                NewFolderSheet(presetCustomer: presetCustomer)
            case .manageFolders:
                ManageFoldersView()
            }
        }
        .navigationTitle("MobaMac")
        .confirmationDialog(
            "Connect to \(pendingProfile?.name ?? "")?",
            isPresented: Binding(
                get: { pendingProfile != nil },
                set: { if !$0 { pendingProfile = nil } }
            ),
            presenting: pendingProfile
        ) { profile in
            Button("Connect") {
                open(profile)
                pendingProfile = nil
            }
            Button("Cancel", role: .cancel) {
                pendingProfile = nil
            }
        } message: { profile in
            Text(connectMessage(for: profile))
        }
        .confirmationDialog(
            "Delete \(profileToDelete?.name ?? "")?",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            ),
            presenting: profileToDelete
        ) { profile in
            Button("Delete", role: .destructive) {
                profileStore.delete(profile)
                profileToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                profileToDelete = nil
            }
        } message: { _ in
            Text("This removes the saved session and its stored credentials. This can't be undone.")
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
            Button("Cancel", role: .cancel) {
                groupPendingDelete = nil
            }
        } message: { group in
            Text(groupDeleteMessage(for: group))
        }
    }

    private func groupDeleteMessage(for group: SessionGroup) -> String {
        if group.parentID == nil {
            let deviceTypes = profileStore.deviceTypeGroups(under: group.id)
            let sessionCount = deviceTypes.reduce(0) { $0 + profileStore.profileCount(in: $1.id) }
            return "This removes the \"\(group.name)\" folder and its \(deviceTypes.count) device-type folder\(deviceTypes.count == 1 ? "" : "s"). \(sessionCount) session\(sessionCount == 1 ? "" : "s") will move to Ungrouped, not be deleted."
        } else {
            let sessionCount = profileStore.profileCount(in: group.id)
            return "\(sessionCount) session\(sessionCount == 1 ? "" : "s") in this folder will move to Ungrouped, not be deleted."
        }
    }

    /// Each of these three used to be an inline branch of `body`'s `List {
    /// }` — pulled out into their own computed properties for the same
    /// reason `customerRow`/`deviceTypeRow` were split out below: the
    /// combined if/else tree got big enough that the type checker gave up
    /// on it as one expression ("unable to type-check this expression in
    /// reasonable time"), and it kept resurfacing at a different line each
    /// time one spot got fixed until the whole `body` was broken up like
    /// this.
    private var recentSection: some View {
        Section("Recent") {
            ForEach(recentProfiles) { profile in
                sessionRow(profile, showBreadcrumb: true)
            }
        }
    }

    private var searchResultsSection: some View {
        Section("Sessions") {
            ForEach(filteredProfiles) { profile in
                sessionRow(profile, showBreadcrumb: true)
            }
        }
    }

    private var groupedSessionsSection: some View {
        Section("Sessions") {
            ForEach(profileStore.customerGroups.sorted { $0.name < $1.name }) { customer in
                customerRow(customer)
            }

            if !ungroupedProfiles.isEmpty {
                ungroupedFolder
            }
        }
    }

    private var ungroupedFolder: some View {
        DisclosureGroup {
            ForEach(ungroupedProfiles) { profile in
                sessionRow(profile, showBreadcrumb: false)
            }
        } label: {
            Label("Ungrouped", systemImage: "questionmark.folder")
                .lineLimit(1)
                .help("Sessions with no customer or device type assigned.")
        }
    }

    /// Toolbar's "+" menu, also split out of `body` rather than inlined in
    /// `.toolbar { }` — same type-checker reasoning as the sections above.
    @ToolbarContentBuilder
    /// `.navigation` puts this at the leading end of the toolbar, next to
    /// the sidebar toggle, rather than in the trailing group that macOS
    /// collapses into the overflow menu first. That is what keeps it
    /// visible at the window's 720pt minimum width, and it is why the
    /// second copy of this menu that used to sit at the bottom of the
    /// sidebar could be removed: with `.navigation` placement plus a
    /// detail toolbar that is now four items instead of nine, nothing is
    /// competing for the space that pushed "New Folder" out of reach in
    /// 1.7. Do not move this to `.automatic` — that was the original bug.
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                addMenuItems
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add a session or folder, or manage existing folders.")
        }
    }

    @ViewBuilder
    private var addMenuItems: some View {
        Button {
            showingNewSession = true
        } label: {
            Label("New Session…", systemImage: "terminal")
        }
        Button {
            activeSheet = .newFolder(presetCustomer: nil)
        } label: {
            Label("New Folder…", systemImage: "folder.badge.plus")
        }
        Divider()
        Button {
            activeSheet = .manageFolders
        } label: {
            Label("Manage Folders…", systemImage: "folder.badge.gearshape")
        }
    }

    /// Outer tree level — one Customer folder. Pulled out of `body` on its
    /// own originally for type-checker reasons (see the note on
    /// `recentSection` above); rewritten to drop `DisclosureGroup` entirely
    /// after its label turned out to have unreliable hit-testing once an
    /// interactive "…" menu button lived inside it — clicks meant for the
    /// menu sometimes got eaten by the disclosure's own expand/collapse
    /// gesture instead, which is why "delete folder" didn't work even
    /// though the action was wired up correctly. A plain `HStack` with two
    /// separate, non-overlapping controls (a chevron `Button` that expands
    /// and a `Menu` that doesn't) has no such ambiguity.
    @ViewBuilder
    private func customerRow(_ customer: SessionGroup) -> some View {
        HStack {
            Button {
                toggleCustomerExpanded(customer.id)
            } label: {
                HStack(spacing: 6) {
                    disclosureChevron(expanded: expandedCustomers.contains(customer.id))
                    Label(customer.name, systemImage: "building.2")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.plain)
            .help("Customer: \(customer.name)")

            Spacer()

            rowActionsMenu(key: "customer-\(customer.id)", help: "Folder actions for \(customer.name).") {
                Button {
                    activeSheet = .newFolder(presetCustomer: customer.name)
                } label: {
                    Label("Add Device Type Folder…", systemImage: "folder.badge.plus")
                }
                Button(role: .destructive) {
                    groupPendingDelete = customer
                } label: {
                    Label("Delete Folder…", systemImage: "trash")
                }
            }
        }
        .contentShape(Rectangle())
        .background(hoverBackground("customer-\(customer.id)"))
        .onHover { updateHover("customer-\(customer.id)", inside: $0) }

        if expandedCustomers.contains(customer.id) {
            ForEach(profileStore.deviceTypeGroups(under: customer.id).sorted { $0.name < $1.name }) { deviceType in
                deviceTypeRow(deviceType, under: customer)
                    .padding(.leading, 16)
                    .transition(.opacity)
            }
        }
    }

    /// Inner tree level — one Device Type folder under a given Customer.
    /// Same manual expand + separate "…" menu as `customerRow`, same
    /// reasoning.
    @ViewBuilder
    private func deviceTypeRow(_ deviceType: SessionGroup, under customer: SessionGroup) -> some View {
        HStack {
            Button {
                toggleDeviceTypeExpanded(deviceType.id)
            } label: {
                HStack(spacing: 6) {
                    disclosureChevron(expanded: expandedDeviceTypes.contains(deviceType.id))
                    Label(deviceType.name, systemImage: deviceTypeIcon(for: deviceType.name))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.plain)
            .help("\(deviceType.name) devices under \(customer.name).")

            Spacer()

            rowActionsMenu(key: "type-\(deviceType.id)", help: "Folder actions for \(deviceType.name).") {
                Button(role: .destructive) {
                    groupPendingDelete = deviceType
                } label: {
                    Label("Delete Folder…", systemImage: "trash")
                }
            }
        }
        .contentShape(Rectangle())
        .background(hoverBackground("type-\(deviceType.id)"))
        .onHover { updateHover("type-\(deviceType.id)", inside: $0) }

        if expandedDeviceTypes.contains(deviceType.id) {
            ForEach(profiles(in: deviceType)) { profile in
                sessionRow(profile, showBreadcrumb: false)
                    .padding(.leading, 16)
                    .transition(.opacity)
            }
        }
    }

    /// Opening a folder animates that one change: the rows it reveals or
    /// hides, and its chevron. Nothing else in the list is given an
    /// animation, so a sidebar of dozens of sessions stays smooth when a
    /// folder is toggled over and over. Under Reduce Motion the rows appear
    /// at once, since rows pushing each other down is movement.
    private func toggleCustomerExpanded(_ id: UUID) {
        withAnimation(Motion.movement(Motion.standard, reduceMotion: reduceMotion)) {
            if expandedCustomers.contains(id) {
                expandedCustomers.remove(id)
            } else {
                expandedCustomers.insert(id)
            }
        }
    }

    private func toggleDeviceTypeExpanded(_ id: UUID) {
        withAnimation(Motion.movement(Motion.standard, reduceMotion: reduceMotion)) {
            if expandedDeviceTypes.contains(id) {
                expandedDeviceTypes.remove(id)
            } else {
                expandedDeviceTypes.insert(id)
            }
        }
    }

    /// Turns a quarter turn when its folder opens, rather than swapping for a
    /// different symbol, which gave SwiftUI nothing to animate between.
    private func disclosureChevron(expanded: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(Motion.movement(Motion.standard, reduceMotion: reduceMotion), value: expanded)
            .frame(width: 10)
    }

    private func hoverBackground(_ key: String) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.primary.opacity(hoveredRowKey == key ? 0.07 : 0))
            .animation(Motion.fade(Motion.rowHover), value: hoveredRowKey == key)
    }

    private func profiles(in deviceType: SessionGroup) -> [SessionProfile] {
        profileStore.profiles
            .filter { $0.groupID == deviceType.id }
            .sorted { $0.name < $1.name }
    }

    /// One session in the tree, in Recent, or in search results.
    ///
    /// The connect button and the actions menu sit side by side rather than
    /// the menu living inside the button's label. A control nested inside
    /// another control fights it for clicks, which is the same trap that
    /// once made "Delete Folder" unreliable on the folder rows (see
    /// `customerRow`). The button's label fills the row so the whole row is
    /// still one click to connect, apart from the menu at the end.
    @ViewBuilder
    private func sessionRow(_ profile: SessionProfile, showBreadcrumb: Bool) -> some View {
        let breadcrumb = showBreadcrumb ? profileStore.breadcrumb(for: profile.groupID) : nil
        let hoverKey = "session-\(profile.id)-\(showBreadcrumb ? "flat" : "tree")"
        HStack(spacing: 6) {
            Button {
                pendingProfile = profile
            } label: {
                HStack(spacing: 6) {
                    StatusDot(state: sessionManager.connectionState(for: profile.id))
                    Image(systemName: icon(for: profile.kind))
                        .help(kindHelpText(for: profile.kind))
                    VStack(alignment: .leading, spacing: 0) {
                        // One line each, cut short with "…" in a narrow
                        // sidebar rather than wrapping or widening the row.
                        Text(profile.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let breadcrumb {
                            Text(breadcrumb)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            rowActionsMenu(key: hoverKey, help: "Actions for \(profile.name).") {
                sessionActions(profile)
            }
        }
        .contentShape(Rectangle())
        .background(hoverBackground(hoverKey))
        .onHover { updateHover(hoverKey, inside: $0) }
        // Kept alongside the new button: right-click is already a habit, and
        // both now open the same three actions.
        .contextMenu {
            sessionActions(profile)
        }
    }

    /// Edit, Duplicate and Delete for a session. Shared by the row's actions
    /// button and its context menu so the two can never drift apart.
    @ViewBuilder
    private func sessionActions(_ profile: SessionProfile) -> some View {
        Button {
            editingProfile = profile
        } label: {
            Label("Edit…", systemImage: "pencil")
        }
        Button {
            duplicatingSession = SidebarView.draft(duplicating: profile, from: profileStore)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button(role: .destructive) {
            profileToDelete = profile
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    /// The "…" button at the end of every sidebar row.
    ///
    /// The colour has to be set this particular way. With
    /// `.menuStyle(.borderlessButton)` the label is drawn by AppKit, which
    /// ignores SwiftUI's foreground style, so the icon kept the default
    /// control colour and all but vanished in dark mode. The button menu
    /// style with a plain button style keeps the label in SwiftUI, where
    /// `Color.primary` applies: white in dark mode and black in light, the
    /// same as the session names beside it. A fixed white would disappear in
    /// light mode instead. The tint is belt and braces for the same colour.
    ///
    /// Shown only while its row is hovered, and faded rather than removed so
    /// it keeps its space: the row's text would otherwise shift sideways
    /// every time the pointer crossed it.
    private func rowActionsMenu<Content: View>(
        key: String,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis.circle")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.primary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .tint(Color.primary)
        .fixedSize()
        .opacity(hoveredRowKey == key ? 1 : 0)
        .animation(Motion.fade(Motion.hover), value: hoveredRowKey == key)
        .help(help)
    }

    /// Moving from one row to the next can deliver the new row's enter before
    /// the old row's exit, so an exit only clears the state if it still
    /// belongs to the row that is leaving.
    private func updateHover(_ key: String, inside: Bool) {
        if inside {
            hoveredRowKey = key
        } else if hoveredRowKey == key {
            hoveredRowKey = nil
        }
    }

    /// Shared with the File menu's Duplicate Session command, so both
    /// produce the same copy and the same warning.
    static func draft(duplicating profile: SessionProfile, from store: ProfileStore) -> SessionDraft {
        let copy = store.duplicate(profile)
        // Only worth warning about when this profile logs in with a password
        // of its own and that password could not be read back. A credential
        // set carries over on its own, and a key or agent login has nothing
        // to copy.
        let needsPassword = profile.kind == .ssh
            && profile.credentialSetID == nil
            && profile.authMethod == .password
            && (copy.secret ?? "").isEmpty
        return SessionDraft(
            profile: copy.profile,
            secret: copy.secret,
            notice: needsPassword ? "Enter the password for this copy." : nil
        )
    }

    private func icon(for kind: SessionKind) -> String {
        switch kind {
        case .ssh: return "network"
        case .local: return "terminal"
        case .telnet: return "cable.connector"
        case .serial: return "cable.connector.horizontal"
        }
    }

    /// Per-kind tooltip for the small session-type icon (UI spec §8) — the
    /// icon alone doesn't read as obviously as "SSH" vs "Telnet" vs "Serial"
    /// at a glance, especially the two cable-connector variants.
    private func kindHelpText(for kind: SessionKind) -> String {
        switch kind {
        case .ssh: return "SSH session"
        case .local: return "Local terminal"
        case .telnet: return "Telnet session (unencrypted)"
        case .serial: return "Serial console session"
        }
    }

    /// Per-device-type icon for the sidebar tree's middle level (UI spec §8
    /// gap: these `DisclosureGroup`s previously had plain text labels with
    /// no icon or tooltip at all). Matches back to `DeviceTypeOption` by
    /// the group's stored name — same lookup `NewSessionSheet` already does
    /// in `populateGroupFieldsIfNeeded` — and falls back to a plain folder
    /// for a device-type name that predates that enum or was typed by hand.
    private func deviceTypeIcon(for groupName: String) -> String {
        guard let option = DeviceTypeOption.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(groupName) == .orderedSame
        }) else {
            return "folder"
        }
        switch option {
        case .firewall: return "lock.shield"
        case .aSwitch: return "square.grid.3x2"
        case .router: return "wifi.router"
        case .wlc: return "antenna.radiowaves.left.and.right"
        case .others: return "folder"
        }
    }

    private func connectMessage(for profile: SessionProfile) -> String {
        switch profile.kind {
        case .ssh:
            return "This opens a new terminal tab connected to \(profile.username.isEmpty ? "" : profile.username + "@")\(profile.host):\(profile.port)."
        case .telnet:
            return "This opens a new terminal tab connected to \(profile.host):\(profile.port) over Telnet (unencrypted)."
        case .serial:
            return "This opens a new terminal tab on \(profile.serialPortPath ?? "the selected serial port") at \(profile.baudRate ?? 9600) baud."
        case .local:
            return "This opens a new local terminal tab."
        }
    }

    private func open(_ profile: SessionProfile) {
        switch profile.kind {
        case .ssh:
            let secret = profileStore.secret(for: profile)
            sessionManager.openSSH(profile: profile, secret: secret)
        case .telnet:
            sessionManager.openTelnet(profile: profile)
        case .serial:
            sessionManager.openSerial(profile: profile)
        case .local:
            sessionManager.openLocal(profile: profile)
        }
    }
}
