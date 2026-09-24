import SwiftUI
import AppKit

/// A row of one-click commands above the terminal.
///
/// The Snippets panel already stores these; the difference is reach. A
/// command run thirty times a day should not need a panel opened first, and
/// the saving adds up. Everything is still managed in the panel, so there is
/// only ever one place a command lives.
struct ButtonBarView: View {
    @EnvironmentObject var snippetStore: SnippetStore
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var profileStore: ProfileStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if visibleSnippets.isEmpty {
                    Text("No snippets are shown in the button bar. Tick one in the Snippets panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleSnippets) { snippet in
                        Button(snippet.name) { run(snippet) }
                            .font(.caption)
                            .disabled(sessionManager.activeSession == nil)
                            .help(helpText(for: snippet))
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 30)
        // Broadcast makes one click reach several devices. That is the
        // intent, but it must not be something you only find out afterwards,
        // so the whole bar changes colour while it applies.
        .background(broadcastCount > 0 ? Color.red.opacity(0.18) : Color.clear)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var deviceType: String? {
        guard let profile = sessionManager.activeSession?.profile else { return nil }
        return profileStore.deviceTypeName(for: profile.groupID)
    }

    private var visibleSnippets: [Snippet] {
        snippetStore.buttonBarSnippets(deviceType: deviceType)
    }

    /// How many sessions a click would actually reach, which is more than
    /// one only when this tab is itself a broadcast target.
    private var broadcastCount: Int {
        guard let session = sessionManager.activeSession,
              sessionManager.broadcastTargetIDs.contains(session.id) else { return 0 }
        return sessionManager.broadcastTargetIDs.count
    }

    private func helpText(for snippet: Snippet) -> String {
        if broadcastCount > 0 {
            return "Sends to \(broadcastCount) broadcast targets: \(snippet.command)"
        }
        return snippet.command
    }

    private func run(_ snippet: Snippet) {
        guard sessionManager.activeSession != nil else { return }
        if snippet.confirmBeforeRunning == true, !confirm(snippet) { return }
        // The same call the Snippets panel and the Snippets menu use, which
        // is also the path a keystroke takes, so broadcast applies exactly as
        // it would to typing.
        sessionManager.sendToActive(snippet.command + "\n")
    }

    private func confirm(_ snippet: Snippet) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Run \"\(snippet.name)\"?"
        var detail = "This will send:\n\n\(snippet.command)"
        if broadcastCount > 0 {
            detail += "\n\nBroadcast is on, so it will be sent to \(broadcastCount) sessions."
        }
        alert.informativeText = detail

        alert.addButton(withTitle: "Cancel")
        let runButton = alert.addButton(withTitle: "Run")
        runButton.hasDestructiveAction = true
        runButton.keyEquivalent = ""

        return alert.runModal() == .alertSecondButtonReturn
    }
}
