import Foundation
import AppKit
import Combine
import Sparkle

/// Wraps Sparkle's standard updater so SwiftUI can drive it.
///
/// `SPUStandardUpdaterController` brings its own UI — the update window with
/// release notes, the download progress, the install-and-relaunch — so there
/// is nothing to build here beyond a menu item and a preference. What this
/// class adds is the small amount of state SwiftUI needs to observe, and one
/// thing Sparkle cannot know on its own: that this app may be holding live
/// SSH sessions to production devices, and restarting itself out from under
/// them is not acceptable.
final class UpdaterController: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    /// Set by the App once the scene exists. The relaunch guard below needs
    /// to ask how many sessions are still connected.
    weak var sessionManager: SessionManager?
    /// False while a check is already running, and for a build with no
    /// update feed configured. Drives whether the menu item is enabled.
    @Published private(set) var canCheckForUpdates = false
    /// Bumped after every check so Preferences can show when it last ran.
    @Published private(set) var lastCheckDate: Date?
    /// Whether this build was made with an EdDSA public key and a feed URL
    /// in its Info.plist. A source build without `Scripts/sparkle-public-key.txt`
    /// has neither, and starting the updater then would greet the user with
    /// an error dialog about a missing feed URL on every launch.
    let isConfigured: Bool

    /// Mirrors Sparkle's own setting rather than keeping a copy. Sparkle
    /// persists it in user defaults itself, so there is nothing to store
    /// here — only a change notification, since this is not `@Published`.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    override init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        isConfigured = !(feed ?? "").isEmpty
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        guard isConfigured else { return }
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        lastCheckDate = controller.updater.lastUpdateCheckDate
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    /// The one place an update can be stopped before it restarts the app.
    ///
    /// Sparkle has no idea what this app is doing; left alone it downloads,
    /// installs and relaunches, and every SSH session goes with it. Being
    /// halfway through a firmware upgrade when the terminal disappears is
    /// the scenario this exists to prevent.
    ///
    /// Returning false lets the relaunch proceed now. Returning true defers
    /// it until `installHandler` is invoked — and deliberately never
    /// invoking it is how "Later" works: the update stays staged and
    /// installs when MobaMac is next quit, which is exactly when no session
    /// is live.
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        let live = sessionManager?.liveSessionCount ?? 0
        guard live > 0 else { return false }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sessions still connected"
        let noun = live == 1 ? "session is" : "sessions are"
        alert.informativeText = "\(live) \(noun) still connected. "
            + "Installing the update will restart MobaMac and disconnect them."
        // Later first, so it is the default end and Return doesn't restart
        // an app someone is working in.
        alert.addButton(withTitle: "Later")
        let installButton = alert.addButton(withTitle: "Install Anyway")
        installButton.hasDestructiveAction = true
        installButton.keyEquivalent = ""

        return alert.runModal() != .alertSecondButtonReturn
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        lastCheckDate = updater.lastUpdateCheckDate
    }
}
