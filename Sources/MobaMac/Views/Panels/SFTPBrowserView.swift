import SwiftUI
import AppKit

/// Graphical SFTP browser, opened over an already-connected SSH session
/// (file transfer over the session's existing SSH connection).
struct SFTPBrowserView: View {
    let ssh: SSHConnectionSession

    @State private var session: SFTPBrowserSession?
    @State private var currentPath = "."
    @State private var entries: [SFTPEntry] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    goUp()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(currentPath == "." || currentPath == "/")

                Text(currentPath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer()

                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }

                Button("Done") { dismiss() }
            }
            .padding(8)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 8)
            }

            List(entries) { entry in
                HStack {
                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                    Text(entry.name)
                    Spacer()
                    if let size = entry.size, !entry.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if entry.isDirectory {
                        currentPath = joinedPath(currentPath, entry.name)
                        Task { await refresh() }
                    } else {
                        Task { await downloadPrompt(entry) }
                    }
                }
                .contextMenu {
                    if !entry.isDirectory {
                        Button("Download…") {
                            Task { await downloadPrompt(entry) }
                        }
                    }
                }
            }
            .overlay {
                if isLoading { ProgressView() }
            }
        }
        .frame(minWidth: 420, minHeight: 460)
        .task {
            await connect()
        }
    }

    private func connect() async {
        isLoading = true
        defer { isLoading = false }
        do {
            session = try await ssh.openSFTPBrowser()
            await refresh()
        } catch {
            errorMessage = "Couldn't open SFTP: \(error.localizedDescription)"
        }
    }

    private func refresh() async {
        guard let session else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await session.listDirectory(atPath: currentPath)
                .sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name < $1.name
                }
        } catch {
            errorMessage = "Couldn't list \(currentPath): \(error.localizedDescription)"
        }
    }

    private func goUp() {
        currentPath = (currentPath as NSString).deletingLastPathComponent
        if currentPath.isEmpty { currentPath = "/" }
        Task { await refresh() }
    }

    private func joinedPath(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    private func downloadPrompt(_ entry: SFTPEntry) async {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await session.download(remotePath: joinedPath(currentPath, entry.name), to: url)
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }
}
