import Foundation

/// The user's chosen "normal" (non-fullscreen) terminal font point size —
/// UI spec's font-size default, adjustable across every open session at
/// once via ⌘+ / ⌘- / ⌘0 (see MobaMacApp's "View" menu) and persisted so
/// it's remembered across launches, same UserDefaults-backed pattern as
/// `LogRetentionManager.retentionDays`.
enum TerminalFontSettings {
    private static let pointSizeKey = "MobaMac.terminalFontPointSize"

    static let defaultPointSize: CGFloat = 12
    static let minPointSize: CGFloat = 8
    static let maxPointSize: CGFloat = 28
    /// How much bigger full screen renders text than the windowed base size
    /// — the same 12→16 relationship `observeFullScreenFontScaling`
    /// originally shipped with, kept as a fixed offset so zooming in
    /// windowed mode still makes full screen proportionally bigger too,
    /// rather than the two ever falling out of sync.
    static let fullScreenBump: CGFloat = 4

    static var pointSize: CGFloat {
        get {
            let stored = UserDefaults.standard.object(forKey: pointSizeKey) as? Double
            return stored.map { CGFloat($0) } ?? defaultPointSize
        }
        set {
            let clamped = Swift.min(Swift.max(newValue, minPointSize), maxPointSize)
            UserDefaults.standard.set(Double(clamped), forKey: pointSizeKey)
        }
    }

    @discardableResult
    static func increase() -> CGFloat {
        pointSize += 1
        return pointSize
    }

    @discardableResult
    static func decrease() -> CGFloat {
        pointSize -= 1
        return pointSize
    }

    static func reset() {
        pointSize = defaultPointSize
    }
}
