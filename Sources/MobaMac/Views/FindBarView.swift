import SwiftUI
import AppKit

/// Search across the active session's scrollback.
///
/// After a few thousand lines of "show running-config", finding one
/// interface means scrolling by hand. This drives SwiftTerm's own buffer
/// search through SessionManager, which keeps SwiftTerm's types out of this
/// file.
///
/// Only the current match is selected. Highlighting every match at once
/// would need SwiftTerm's search service, which it does not make public.
struct FindBarView: View {
    @ObservedObject var session: OpenSession
    @EnvironmentObject var sessionManager: SessionManager
    @Binding var isPresented: Bool

    @State private var term = ""
    @State private var caseSensitive = false
    @State private var useRegex = false
    @State private var summary = SessionManager.FindSummary()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in terminal", text: $term)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit {
                    // Shift-Return goes backwards. Read live, because
                    // onSubmit doesn't say which modifiers were held.
                    step(forward: !NSEvent.modifierFlags.contains(.shift))
                }
                .onChange(of: term) { _, _ in step(forward: true) }
                .onChange(of: caseSensitive) { _, _ in step(forward: true) }
                .onChange(of: useRegex) { _, _ in step(forward: true) }

            Text(countText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)

            Button { step(forward: false) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(summary.total == 0)
            .help("Previous match (Shift-Return).")

            Button { step(forward: true) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(summary.total == 0)
            .help("Next match (Return).")

            Toggle("Aa", isOn: $caseSensitive)
                .toggleStyle(.button)
                .help("Match upper and lower case exactly.")

            Toggle(".*", isOn: $useRegex)
                .toggleStyle(.button)
                .help("Treat the search text as a regular expression.")

            Button { close() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close the find bar (Esc).")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onExitCommand { close() }
        .onAppear { fieldFocused = true }
        // Searching one session's scrollback and then switching tabs would
        // otherwise leave a stale count next to a different device.
        .onChange(of: session.id) { _, _ in
            summary = SessionManager.FindSummary()
        }
    }

    private var countText: String {
        if term.isEmpty { return "" }
        if summary.total == 0 { return "No matches" }
        return "\(summary.index) of \(summary.total)"
    }

    private func step(forward: Bool) {
        guard !term.isEmpty else {
            summary = SessionManager.FindSummary()
            sessionManager.clearTerminalSearch(in: session)
            return
        }
        summary = sessionManager.findInTerminal(
            term,
            session: session,
            caseSensitive: caseSensitive,
            regex: useRegex,
            forward: forward
        )
    }

    private func close() {
        sessionManager.clearTerminalSearch(in: session)
        isPresented = false
        // Focus goes back where typing belongs, rather than nowhere.
        sessionManager.focusTerminal(of: session)
    }
}
