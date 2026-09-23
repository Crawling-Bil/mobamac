import SwiftUI
import AppKit

/// Every session already tees its raw bytes to
/// ~/Library/Logs/MobaMac/<yyyy-MM-dd_HH-mm-ss>_<name>.log (SessionLogger),
/// independent of on-screen scrollback. This just gives you a way to browse
/// and read those files without leaving the app or hunting through Finder.
struct LogViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logFiles: [URL] = []
    @State private var selectedLog: URL?
    @State private var logContent: String = ""
    /// UI spec §9.5 — mirrors `LogRetentionManager.retentionDays`, which is
    /// the actual source of truth (UserDefaults); this is just what the
    /// Menu below binds to so its checkmark stays in sync.
    @State private var retentionDays: Int = LogRetentionManager.retentionDays

    private var logDirectory: URL { LogRetentionManager.logDirectory }

    var body: some View {
        NavigationSplitView {
            List(logFiles, id: \.self, selection: $selectedLog) { url in
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .tag(url)
            }
            .navigationTitle("Session Logs")
            .toolbar {
                ToolbarItem {
                    retentionMenu
                }
                ToolbarItem {
                    Button {
                        refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                ToolbarItem {
                    Button {
                        revealSelectedLogInFinder()
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .disabled(selectedLog == nil)
                    .help("Reveal the selected log file in Finder so you can copy it.")
                }
            }
        } detail: {
            if let selectedLog {
                ScrollView {
                    Text(logContent)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(selectedLog.lastPathComponent)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Pick a log to view it")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 800, height: 520)
        .onAppear { refresh() }
        .onChange(of: selectedLog) { _, newValue in
            loadContent(newValue)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }

    /// UI spec §9.5: how long session logs are kept before being
    /// auto-deleted. Picking a shorter window purges immediately (not just
    /// "starting from your next launch") so the setting visibly does
    /// something the moment you change it, and the list refreshes to match.
    private var retentionMenu: some View {
        Menu {
            ForEach([7, 30, 90, 0], id: \.self) { days in
                Button {
                    setRetention(days)
                } label: {
                    if retentionDays == days {
                        Label(retentionLabel(for: days), systemImage: "checkmark")
                    } else {
                        Text(retentionLabel(for: days))
                    }
                }
            }
        } label: {
            Label("Keep logs for \(retentionLabel(for: retentionDays))", systemImage: "clock.arrow.circlepath")
        }
        .help("How long session logs are kept before MobaMac deletes them. Choose \"Forever\" to disable automatic cleanup.")
    }

    private func retentionLabel(for days: Int) -> String {
        days == 0 ? "Forever" : "\(days) days"
    }

    private func setRetention(_ days: Int) {
        retentionDays = days
        LogRetentionManager.retentionDays = days
        LogRetentionManager.purgeExpiredLogs()
        refresh()
    }

    /// Pulled out into its own function, same as `refresh()` — Swift's
    /// type-checker choked on an `if let` written directly inside a
    /// Button's action closure nested in a ToolbarItem/ToolbarItemGroup
    /// ("unable to type-check this expression in reasonable time"). A
    /// plain function call as the closure body sidesteps that entirely.
    private func revealSelectedLogInFinder() {
        guard let selectedLog else { return }
        // The Swift-friendly NSWorkspace API takes an array of URLs, not a
        // single path string — `activateFileViewerSelectingPath` doesn't
        // exist (that was the old Objective-C `...Paths:` API, misremembered).
        NSWorkspace.shared.activateFileViewerSelecting([selectedLog])
    }

    private func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: logDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        logFiles = files
            .filter { $0.pathExtension == "log" }
            .sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return d0 > d1
            }
    }

    private func loadContent(_ url: URL?) {
        guard let url else {
            logContent = ""
            return
        }
        // Logs can get large; cap what actually gets pulled into memory/rendered.
        let maxBytes = 2_000_000
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            logContent = "(couldn't open this log file)"
            return
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        var text = String(decoding: data, as: UTF8.self)
        text = Self.stripTerminalEscapes(text)
        if offset > 0 {
            text = "… (showing the last \(maxBytes / 1000) KB) …\n\n" + text
        }
        logContent = text
    }

    /// Session logs are a byte-for-byte capture of everything the PTY
    /// produced — including every ANSI/VT100 escape sequence a themed
    /// prompt (Powerlevel10k and similar) emits for colors, cursor
    /// movement, and line redraws. A real terminal interprets those; a
    /// plain Text view just shows the raw codes, which is what was
    /// showing up as garbled brackets/numbers. Strip it down to the
    /// visible characters instead.
    private static func stripTerminalEscapes(_ text: String) -> String {
        var result = text
        // OSC sequences: ESC ] ... terminated by BEL or ESC \
        result = result.replacingOccurrences(
            of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",
            with: "", options: .regularExpression
        )
        // CSI sequences: ESC [ ... final letter (cursor moves, colors, clears)
        result = result.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z@]",
            with: "", options: .regularExpression
        )
        // Charset-select and other two-byte escapes, plus any lone ESC left over
        result = result.replacingOccurrences(
            of: "\u{1B}[()][A-Za-z0-9]|\u{1B}[=>78M]",
            with: "", options: .regularExpression
        )
        result = result.replacingOccurrences(of: "\u{1B}", with: "")
        // A themed prompt redraws its line with a bare \r rather than \n —
        // turn each of those into a real line break instead of letting the
        // text silently overlap.
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "\r", with: "\n")
        // Whatever non-printable control bytes are left (keep tab/newline).
        result = result.replacingOccurrences(
            of: "[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]",
            with: "", options: .regularExpression
        )
        return result
    }
}
