import SwiftUI

/// Toolbar-accessible panel for snippets: saved commands sent to the active
/// session with one click instead of being retyped or hunted out of shell
/// history. A snippet with a keyboard shortcut can also be run without
/// opening this panel at all, from the "Snippets" menu MobaMacApp builds
/// from the same SnippetStore.
struct SnippetsPanelView: View {
    @EnvironmentObject var snippetStore: SnippetStore
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var editingSnippet: Snippet?
    @State private var showingNewSnippet = false
    /// Set instead of deleting immediately when the target snippet is more
    /// than one line (UI spec §10). A one-line snippet deletes without
    /// asking, since confirming that is friction for no benefit, but losing
    /// a multi-line snippet, a saved config block for instance, deserves a
    /// speed bump.
    @State private var snippetPendingDelete: Snippet?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Snippets").font(.title2.bold())
                Spacer()
                Button {
                    showingNewSnippet = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                Button("Close") { dismiss() }
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            if snippetStore.snippets.isEmpty {
                VStack(spacing: 8) {
                    Text("No snippets yet").font(.headline)
                    Text("Save commands you run often and send them to the active session with one click.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(snippetStore.snippets) { snippet in
                        HStack {
                            // Ticking this is the only way into the button
                            // bar, so the panel stays the one place snippets
                            // are managed.
                            Toggle("", isOn: Binding(
                                get: { snippet.isInButtonBar },
                                set: { newValue in
                                    var updated = snippet
                                    updated.showInButtonBar = newValue ? true : nil
                                    if newValue, updated.buttonBarOrder == nil {
                                        updated.buttonBarOrder = snippetStore.snippets.count
                                    }
                                    snippetStore.upsert(updated)
                                }
                            ))
                            .labelsHidden()
                            .help("Show this snippet as a button above the terminal.")

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(snippet.name).font(.body.bold())
                                    if let key = snippet.shortcutKey, !key.isEmpty {
                                        Text("⌥⌘\(key.uppercased())")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                                Text(snippet.command)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Run") {
                                sessionManager.sendToActive(snippet.command + "\n")
                            }
                            .disabled(sessionManager.activeSession == nil)
                            .help("Run this snippet in the active session.")

                            // Standalone icon-only delete, alongside the
                            // context-menu entry and swipe-to-delete below —
                            // spec §10 wants all three reachable, since swipe
                            // is what trackpad users find and right-click is
                            // what most people reach for first on macOS.
                            Button {
                                requestDelete(snippet)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete this snippet.")
                        }
                        .contextMenu {
                            Button {
                                editingSnippet = snippet
                            } label: {
                                Label("Edit…", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                requestDelete(snippet)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete(perform: deleteAtOffsets)
                    // Dragging here is what sets the button bar's order, so
                    // the row of buttons matches the list you are looking at.
                    .onMove { offsets, destination in
                        snippetStore.move(fromOffsets: offsets, toOffset: destination)
                    }
                }
            }
        }
        .frame(width: 460, height: 400)
        .sheet(isPresented: $showingNewSnippet) {
            SnippetEditSheet(snippetToEdit: nil, existingSnippets: snippetStore.snippets)
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditSheet(snippetToEdit: snippet, existingSnippets: snippetStore.snippets)
        }
        .confirmationDialog(
            "Delete \"\(snippetPendingDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { snippetPendingDelete != nil },
                set: { if !$0 { snippetPendingDelete = nil } }
            ),
            presenting: snippetPendingDelete
        ) { snippet in
            Button("Delete", role: .destructive) {
                snippetStore.delete(snippet)
                snippetPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                snippetPendingDelete = nil
            }
        } message: { _ in
            Text("This snippet contains multiple lines. This can't be undone.")
        }
    }

    /// One-line snippets delete immediately; anything longer routes through
    /// the confirmation dialog above (UI spec §10).
    private func requestDelete(_ snippet: Snippet) {
        if isMultiLine(snippet) {
            snippetPendingDelete = snippet
        } else {
            snippetStore.delete(snippet)
        }
    }

    private func deleteAtOffsets(_ offsets: IndexSet) {
        for index in offsets {
            requestDelete(snippetStore.snippets[index])
        }
    }

    private func isMultiLine(_ snippet: Snippet) -> Bool {
        snippet.command.contains("\n")
    }
}

private struct SnippetEditSheet: View {
    @EnvironmentObject var snippetStore: SnippetStore
    @Environment(\.dismiss) private var dismiss

    private let editingID: UUID?
    private let existingSnippets: [Snippet]
    @State private var name: String
    @State private var command: String
    @State private var shortcutKey: String
    @State private var deviceTypes: Set<SnippetDeviceType>
    @State private var confirmBeforeRunning: Bool
    @State private var showInButtonBar: Bool

    init(snippetToEdit: Snippet?, existingSnippets: [Snippet]) {
        editingID = snippetToEdit?.id
        self.existingSnippets = existingSnippets
        _name = State(initialValue: snippetToEdit?.name ?? "")
        _command = State(initialValue: snippetToEdit?.command ?? "")
        _shortcutKey = State(initialValue: snippetToEdit?.shortcutKey ?? "")
        _deviceTypes = State(initialValue: Set(snippetToEdit?.deviceTypes ?? []))
        _confirmBeforeRunning = State(initialValue: snippetToEdit?.confirmBeforeRunning ?? false)
        _showInButtonBar = State(initialValue: snippetToEdit?.isInButtonBar ?? false)
        existingOrder = snippetToEdit?.buttonBarOrder
    }

    private let existingOrder: Int?

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !command.isEmpty
    }

    /// Someone else already using the same key isn't fatal — AppKit just
    /// ends up honoring one of them — but it's confusing enough to flag
    /// before it bites you rather than after.
    private var duplicateShortcutName: String? {
        guard !shortcutKey.isEmpty else { return nil }
        return existingSnippets.first {
            $0.id != editingID && ($0.shortcutKey?.uppercased() == shortcutKey.uppercased())
        }?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editingID == nil ? "New Snippet" : "Edit Snippet").font(.title2.bold())
            TextField("Name", text: $name)
            TextField("Command", text: $command)
                .font(.system(.body, design: .monospaced))
            Text("Sent to the active session followed by Enter.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Keyboard shortcut (optional)", text: $shortcutKey)
                .frame(width: 200)
                .onChange(of: shortcutKey) { _, newValue in
                    if let last = newValue.last, last.isLetter || last.isNumber {
                        shortcutKey = String(last).uppercased()
                    } else {
                        shortcutKey = ""
                    }
                }
            Text(shortcutKey.isEmpty
                 ? "Assign a letter or digit to run this snippet with ⌥⌘ and that key from anywhere in the app."
                 : "Runs with ⌥⌘\(shortcutKey) from anywhere in the app, including while a terminal is focused.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()

            Toggle("Show in button bar", isOn: $showInButtonBar)

            VStack(alignment: .leading, spacing: 4) {
                Text("Show for device types")
                    .font(.callout)
                HStack(spacing: 10) {
                    ForEach(SnippetDeviceType.allCases) { type in
                        Toggle(type.rawValue, isOn: Binding(
                            get: { deviceTypes.contains(type) },
                            set: { isOn in
                                if isOn { deviceTypes.insert(type) } else { deviceTypes.remove(type) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                Text("Leave all unticked to show this snippet for every session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!showInButtonBar)

            Toggle("Confirm before running", isOn: $confirmBeforeRunning)
                .help("Asks first. Worth turning on for commands like reload, write erase or commit force.")

            if let duplicateShortcutName {
                Label(
                    "\"\(duplicateShortcutName)\" already uses ⌥⌘\(shortcutKey). Only one of them will run.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    snippetStore.upsert(Snippet(
                        id: editingID ?? UUID(),
                        name: name,
                        command: command,
                        shortcutKey: shortcutKey.isEmpty ? nil : shortcutKey,
                        showInButtonBar: showInButtonBar ? true : nil,
                        buttonBarOrder: existingOrder ?? snippetStore.snippets.count,
                        deviceTypes: deviceTypes.isEmpty ? nil : SnippetDeviceType.allCases.filter { deviceTypes.contains($0) },
                        confirmBeforeRunning: confirmBeforeRunning ? true : nil
                    ))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
