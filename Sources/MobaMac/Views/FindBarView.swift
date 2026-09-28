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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the bar's own fade and short drop. The space the bar takes is
    /// inserted and removed instantly by ContentView, so the terminal below
    /// is resized exactly once each way; only the bar's contents move.
    @State private var shown = false
    @State private var closing = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            // A real field rather than a plain one. Borderless, it sat
            // directly on the bar's own material with no edge of its own,
            // so there was nothing to tell you where to type.
            TextField("Find in terminal", text: $term)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            fieldFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: fieldFocused ? 2 : 1
                        )
                )
                .frame(minWidth: 240)
                .focused($fieldFocused)
                .onSubmit {
                    // Shift-Return goes backwards. Read live, because
                    // onSubmit doesn't say which modifiers were held.
                    step(forward: !NSEvent.modifierFlags.contains(.shift))
                }
                .onChange(of: term) { _, _ in step(forward: true) }
                .onChange(of: caseSensitive) { _, _ in step(forward: true) }
                .onChange(of: useRegex) { _, _ in step(forward: true) }

            // The one thing that stays small, and fixed so a narrow window
            // squeezes the field rather than clipping the buttons.
            Text(countText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(minWidth: 56, alignment: .trailing)

            Button { step(forward: false) } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .disabled(summary.total == 0)
            .help("Previous match (Shift-Return).")

            Button { step(forward: true) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .disabled(summary.total == 0)
            .help("Next match (Return).")

            Toggle("Aa", isOn: $caseSensitive)
                .toggleStyle(.button)
                .font(.system(size: 12))
                .help("Match upper and lower case exactly.")

            Toggle(".*", isOn: $useRegex)
                .toggleStyle(.button)
                .font(.system(size: 12))
                .help("Treat the search text as a regular expression.")

            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Close the find bar (Esc).")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : -8)
        .clipped()
        .onExitCommand { close() }
        .onAppear {
            fieldFocused = true
            withAnimation(.easeOut(duration: Motion.findBarIn)) { shown = true }
        }
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
        guard !closing else { return }
        closing = true
        sessionManager.clearTerminalSearch(in: session)
        withAnimation(.easeIn(duration: Motion.findBarOut)) { shown = false }
        // The bar's space is given back only once it has faded, in one step,
        // so the terminal resizes once rather than following the animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.findBarOut) {
            isPresented = false
            // Focus goes back where typing belongs, rather than nowhere.
            sessionManager.focusTerminal(of: session)
        }
    }
}
