import SwiftUI
import AppKit

/// The Settings window (⌘,). A `Settings` scene rather than a sheet, so
/// macOS puts "Settings…" in the app menu and manages the window itself.
struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem { Label("General", systemImage: "gearshape") }
            TerminalPreferencesView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            LoggingPreferencesView()
                .tabItem { Label("Logging", systemImage: "doc.text") }
        }
        .frame(width: 540, height: 280)
    }
}

private struct GeneralPreferencesView: View {
    @EnvironmentObject var appearanceSettings: AppearanceSettings
    @EnvironmentObject var updater: UpdaterController
    /// Read once into local state because the dialog's suppression checkbox
    /// can change it behind this view's back; reopening Settings re-reads it.
    @State private var confirmClose = CloseConfirmationSettings.isEnabled

    private var lastCheckedText: String {
        guard let date = updater.lastCheckDate else { return "Not checked yet." }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Last checked \(formatter.string(from: date))."
    }

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearanceSettings.appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            Text("Applies to the app's own windows. The terminal keeps its own color theme.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 4)

            Toggle("Confirm before closing a connected session", isOn: $confirmClose)
                .onChange(of: confirmClose) { _, newValue in
                    CloseConfirmationSettings.isEnabled = newValue
                }
            Text("Ticking \"Don't ask again\" in that dialog turns this off. This is where to turn it back on.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 4)

            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))
            .disabled(!updater.isConfigured)

            HStack {
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                if !updater.isConfigured {
                    Text("This build has no update feed configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Worth showing: a background check that quietly stopped
                    // working looks exactly like no updates being released.
                    Text(lastCheckedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("MobaMac asks before installing, and will not restart while a session is still connected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct TerminalPreferencesView: View {
    @State private var copyOnSelect = TerminalBehaviorSettings.copyOnSelect
    @State private var rightClickPastes = TerminalBehaviorSettings.rightClickPastes

    var body: some View {
        Form {
            Toggle("Copy on select", isOn: $copyOnSelect)
                .onChange(of: copyOnSelect) { _, newValue in
                    TerminalBehaviorSettings.copyOnSelect = newValue
                }
            Text("Selecting text in the terminal puts it on the clipboard straight away, the way MobaXterm and PuTTY do. A click with nothing selected leaves the clipboard alone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 4)

            Toggle("Right-click pastes", isOn: $rightClickPastes)
                .onChange(of: rightClickPastes) { _, newValue in
                    TerminalBehaviorSettings.rightClickPastes = newValue
                }
            Text("Right-clicking in the terminal pastes instead of opening the context menu. Control-click still opens the menu. Pasting several lines asks for confirmation either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct LoggingPreferencesView: View {
    /// Mirrors what is in UserDefaults so the fields redraw after a change.
    /// The settings themselves are the source of truth; these are just the
    /// view's copy.
    @State private var directoryPath = LogSettings.activeDirectory.path
    @State private var keepRawLogs = LogSettings.keepRawLogs
    @State private var retentionDays = LogRetentionManager.retentionDays

    private static let retentionChoices = [0, 7, 30, 90, 365]

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 6) {
                Text("Session log folder")
                    .font(.callout)
                Text(directoryPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack {
                    Button("Choose…", action: chooseFolder)
                    Button("Reveal in Finder", action: revealFolder)
                    Button("Reset to Default", action: resetFolder)
                        .disabled(LogSettings.configuredDirectory == nil)
                }
                Text("Applies to new sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
                .padding(.vertical, 4)

            Toggle("Keep raw session logs (with color codes)", isOn: $keepRawLogs)
                .onChange(of: keepRawLogs) { _, newValue in
                    LogSettings.keepRawLogs = newValue
                }
            Text("Writes a .raw file beside each .log. Useful when you need to see what the device actually sent.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Delete logs older than", selection: $retentionDays) {
                ForEach(Self.retentionChoices, id: \.self) { days in
                    Text(days == 0 ? "Never" : "\(days) days").tag(days)
                }
            }
            .onChange(of: retentionDays) { _, newValue in
                LogRetentionManager.retentionDays = newValue
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where MobaMac writes session logs."
        panel.directoryURL = LogSettings.activeDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        LogSettings.setDirectory(url)
        directoryPath = url.path
    }

    private func revealFolder() {
        let url = LogSettings.activeDirectory
        // A folder that has never been written to doesn't exist yet, and
        // Finder just beeps at a path that isn't there.
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func resetFolder() {
        LogSettings.resetDirectoryToDefault()
        directoryPath = LogSettings.defaultDirectory.path
    }
}
