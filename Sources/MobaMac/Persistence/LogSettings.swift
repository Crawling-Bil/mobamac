import Foundation
import Combine

/// Where session logs go, and in what form.
///
/// The folder is a user choice rather than a fixed path because the logs are
/// documentation: people keep them next to the rest of a customer's files, or
/// in a synced folder, not buried in ~/Library where nothing else of theirs
/// lives.
enum LogSettings {
    private static let keepRawLogsKey = "MobaMac.keepRawSessionLogs"
    private static let directoryBookmarkKey = "MobaMac.logDirectoryBookmark"
    private static let directoryPathKey = "MobaMac.logDirectoryPath"

    /// Also keep the unfiltered byte stream beside each `.log`, as `.raw`.
    ///
    /// Off by default: the whole point of the filter is that the log reads
    /// like a document. But when something on screen looks wrong — a prompt
    /// that redraws oddly, output that wraps where it shouldn't — the escape
    /// sequences are the evidence, and by then the session is over.
    static var keepRawLogs: Bool {
        get { UserDefaults.standard.bool(forKey: keepRawLogsKey) }
        set { UserDefaults.standard.set(newValue, forKey: keepRawLogsKey) }
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MobaMac", isDirectory: true)
    }

    /// The folder the user picked, or nil when they never picked one.
    ///
    /// Stored as a security-scoped bookmark rather than a path string.
    /// MobaMac is not sandboxed today, so a path would work — but a bookmark
    /// also survives the folder being renamed or moved, and having it in
    /// place means turning the sandbox on later is a build setting rather
    /// than a redesign. The path is stored alongside it purely so
    /// Preferences has something to display when the bookmark won't resolve.
    static var configuredDirectory: URL? {
        if let data = UserDefaults.standard.data(forKey: directoryBookmarkKey) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
            // A bookmark made without the security-scope option (see
            // setDirectory) resolves without it too.
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }
        if let path = UserDefaults.standard.string(forKey: directoryPathKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    /// What Preferences shows and what the Log Viewer browses: the chosen
    /// folder if there is one, the default otherwise. Not a promise that it
    /// is writable — `resolveForWriting()` is what checks that.
    static var activeDirectory: URL {
        configuredDirectory ?? defaultDirectory
    }

    static func setDirectory(_ url: URL) {
        // Security scope needs the sandbox entitlement to be granted; a
        // plain bookmark is the fallback for an unsandboxed build, and the
        // path is the fallback for both.
        let bookmark = (try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )) ?? (try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ))

        if let bookmark {
            UserDefaults.standard.set(bookmark, forKey: directoryBookmarkKey)
        } else {
            UserDefaults.standard.removeObject(forKey: directoryBookmarkKey)
        }
        UserDefaults.standard.set(url.path, forKey: directoryPathKey)
    }

    static func resetDirectoryToDefault() {
        UserDefaults.standard.removeObject(forKey: directoryBookmarkKey)
        UserDefaults.standard.removeObject(forKey: directoryPathKey)
    }

    /// What a `SessionLogger` should open, having checked it can actually be
    /// written to.
    ///
    /// The chosen folder can be gone: renamed, on a drive that is unplugged,
    /// inside a network share that is offline. A failure here must never
    /// take the connection down with it — the session matters, the log is a
    /// by-product — so this falls back to the default folder and says so.
    struct Resolved {
        let url: URL
        /// True when the chosen folder could not be used and this is the
        /// default instead. The status bar says so once.
        let didFallBack: Bool
        /// Set when security-scoped access was started and has to be stopped
        /// when the log closes.
        let scopedRoot: URL?
    }

    static func resolveForWriting() -> Resolved {
        if let chosen = configuredDirectory {
            let started = chosen.startAccessingSecurityScopedResource()
            if isUsable(chosen) {
                return Resolved(url: chosen, didFallBack: false, scopedRoot: started ? chosen : nil)
            }
            if started { chosen.stopAccessingSecurityScopedResource() }
            let fallback = defaultDirectory
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            return Resolved(url: fallback, didFallBack: true, scopedRoot: nil)
        }

        let fallback = defaultDirectory
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return Resolved(url: fallback, didFallBack: false, scopedRoot: nil)
    }

    private static func isUsable(_ url: URL) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue && manager.isWritableFile(atPath: url.path)
        }
        // Recreate it only when its parent is still there, and never with
        // intermediate directories. An unplugged drive leaves nothing at
        // /Volumes/<name>, and creating intermediates would cheerfully build
        // that path on the boot disk instead — logs written into a phantom
        // folder that vanishes the moment the real drive comes back.
        let parent = url.deletingLastPathComponent()
        guard manager.fileExists(atPath: parent.path) else { return false }
        guard (try? manager.createDirectory(at: url, withIntermediateDirectories: false)) != nil else {
            return false
        }
        return manager.isWritableFile(atPath: url.path)
    }
}

/// Carries a logging problem from `SessionLogger`, which has no view, to the
/// status bar, which has no idea a log was opened.
final class LogStatus: ObservableObject {
    static let shared = LogStatus()

    @Published var warning: String?

    private init() {}

    func reportFallback() {
        set("Log folder unavailable, using the default location.")
    }

    func clear() {
        set(nil)
    }

    private func set(_ value: String?) {
        if Thread.isMainThread {
            if warning != value { warning = value }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.warning != value else { return }
                self.warning = value
            }
        }
    }
}
