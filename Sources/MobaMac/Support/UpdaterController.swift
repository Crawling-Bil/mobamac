import Foundation
import Combine
import Sparkle

/// Wraps Sparkle's standard updater so SwiftUI can drive it.
///
/// `SPUStandardUpdaterController` brings its own UI — the update window with
/// release notes, the download progress, the install-and-relaunch — so there
/// is nothing to build here beyond a menu item and a preference. What this
/// class adds is the small amount of state SwiftUI needs to observe:
/// whether a check is possible right now, and whether background checks are
/// on.
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController
    /// False while a check is already running, and for a build with no
    /// update feed configured. Drives whether the menu item is enabled.
    @Published private(set) var canCheckForUpdates = false
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

    init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        isConfigured = !(feed ?? "").isEmpty
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        guard isConfigured else { return }
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }
}
