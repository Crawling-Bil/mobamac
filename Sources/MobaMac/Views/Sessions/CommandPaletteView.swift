import SwiftUI

/// ⌘K quick-open (UI spec §4). Flattens every saved profile into a single
/// live-filtered list, breadcrumbed with its Customer / Device Type via
/// `ProfileStore.breadcrumb(for:)`. Arrow keys move the selection, Enter
/// connects, Esc closes — deliberately no "are you sure?" step here, unlike
/// the sidebar's confirm dialog: a command palette is supposed to be the
/// fast path.
struct CommandPaletteView: View {
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedID: SessionProfile.ID?
    @FocusState private var searchFocused: Bool

    private var results: [SessionProfile] {
        let all = profileStore.profiles
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { profile in
            profile.name.localizedCaseInsensitiveContains(query) ||
            profile.host.localizedCaseInsensitiveContains(query) ||
            (profileStore.breadcrumb(for: profile.groupID) ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Jump to a session…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($searchFocused)
                .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                .onKeyPress(.return) { connectToSelection(); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }

            Divider()

            if results.isEmpty {
                Text("No matching sessions")
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                List(results, selection: $selectedID) { profile in
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: profile.kind))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(profile.name)
                            if let breadcrumb = profileStore.breadcrumb(for: profile.groupID) {
                                Text(breadcrumb)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        selectedID = profile.id
                        connectToSelection()
                    }
                }
                .frame(minHeight: 240, maxHeight: 360)
            }
        }
        .frame(width: 480)
        .onAppear {
            searchFocused = true
            if selectedID == nil {
                selectedID = results.first?.id
            }
        }
        .onChange(of: query) { _, _ in
            selectedID = results.first?.id
        }
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let currentIndex = results.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : 0)
        let newIndex = min(max(currentIndex + delta, 0), results.count - 1)
        selectedID = results[newIndex].id
    }

    private func connectToSelection() {
        guard let selectedID, let profile = results.first(where: { $0.id == selectedID }) else { return }
        switch profile.kind {
        case .ssh:
            sessionManager.openSSH(profile: profile, secret: profileStore.secret(for: profile))
        case .telnet:
            sessionManager.openTelnet(profile: profile)
        case .serial:
            sessionManager.openSerial(profile: profile)
        case .local:
            sessionManager.openLocal(profile: profile)
        }
        dismiss()
    }

    private func icon(for kind: SessionKind) -> String {
        switch kind {
        case .ssh: return "network"
        case .local: return "terminal"
        case .telnet: return "cable.connector"
        case .serial: return "cable.connector.horizontal"
        }
    }
}
