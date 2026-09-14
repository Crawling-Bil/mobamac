import SwiftUI

/// Presented from the toolbar's Broadcast button (UI spec §3 — the
/// broadcast-scoping safety fix). Lets the user choose exactly which open
/// SSH tabs share keystrokes with each other, instead of the old
/// all-or-nothing `broadcastEnabled` toggle. Sessions outside the active
/// tab's customer are flagged in orange — checking one of those has to be
/// a deliberate choice, not a side effect of turning broadcast on.
struct BroadcastPopoverView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var profileStore: ProfileStore

    private var activeCustomerID: UUID? {
        profileStore.topLevelCustomerID(for: sessionManager.activeSession?.profile.groupID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Broadcast keystrokes to:")
                .font(.headline)

            if sessionManager.openSSHSessions.isEmpty {
                Text("No open SSH tabs.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(sessionManager.openSSHSessions) { session in
                    broadcastRow(session)
                }

                Divider()

                Button("Turn Off Broadcast") {
                    sessionManager.broadcastTargetIDs.removeAll()
                }
                .disabled(sessionManager.broadcastTargetIDs.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    @ViewBuilder
    private func broadcastRow(_ session: OpenSession) -> some View {
        let sameCustomer = activeCustomerID != nil
            && profileStore.topLevelCustomerID(for: session.profile.groupID) == activeCustomerID
        let breadcrumb = profileStore.breadcrumb(for: session.profile.groupID)

        Toggle(isOn: targetBinding(for: session.id)) {
            VStack(alignment: .leading, spacing: 0) {
                Text(session.profile.name)
                Text(breadcrumb ?? "Ungrouped")
                    .font(.caption2)
                    .foregroundStyle(sameCustomer ? Color.secondary : Color.orange)
            }
        }
    }

    private func targetBinding(for id: OpenSession.ID) -> Binding<Bool> {
        Binding(
            get: { sessionManager.broadcastTargetIDs.contains(id) },
            set: { isOn in
                if isOn {
                    sessionManager.broadcastTargetIDs.insert(id)
                } else {
                    sessionManager.broadcastTargetIDs.remove(id)
                }
            }
        )
    }
}
