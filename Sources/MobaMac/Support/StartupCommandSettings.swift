import Foundation

/// Timing for the startup commands a session sends after connecting.
///
/// Both are adjustable because "ready for input" is not something a device
/// announces. A console server in front of a slow switch, or a device that
/// prints a long banner in bursts, needs more room than the defaults give.
enum StartupCommandSettings {
    private static let quietKey = "MobaMac.startupQuietMilliseconds"
    private static let lineDelayKey = "MobaMac.startupLineDelayMilliseconds"

    /// How long the device has to stay silent before the first command is
    /// sent. Sending the moment the connection opens is the classic mistake:
    /// the device is often still printing its login banner and has not
    /// started reading input, so the command vanishes without a trace.
    static var quietMilliseconds: Int {
        get { UserDefaults.standard.object(forKey: quietKey) as? Int ?? 500 }
        set { UserDefaults.standard.set(max(0, newValue), forKey: quietKey) }
    }

    /// Gap between commands, so a device that echoes and redraws has time to
    /// finish before the next line arrives.
    static var lineDelayMilliseconds: Int {
        get { UserDefaults.standard.object(forKey: lineDelayKey) as? Int ?? 300 }
        set { UserDefaults.standard.set(max(0, newValue), forKey: lineDelayKey) }
    }
}
