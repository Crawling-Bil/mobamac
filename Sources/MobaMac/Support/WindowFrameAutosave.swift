import SwiftUI
import AppKit

/// Turns on AppKit's built-in window-frame autosave (UI spec: window
/// defaults — remember size/position across launches). There's no direct
/// SwiftUI API for this, and a plain `WindowGroup` app has no
/// `NSWindowController` of its own to hang `setFrameAutosaveName` off of —
/// a functionally-invisible `NSViewRepresentable` is the standard way to
/// reach the real `NSWindow` from inside a SwiftUI view tree. Drop this
/// anywhere in the view hierarchy (e.g. `.background(WindowFrameAutosave())`
/// on the root view) and AppKit takes care of the rest: it saves the frame
/// to `~/Library/Preferences` on every move/resize from then on.
struct WindowFrameAutosave: NSViewRepresentable {
    static let autosaveName = "MobaMacMainWindow"

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // `window` doesn't exist yet at `makeNSView` time — the view hasn't
        // been inserted into the window's hierarchy — so this defers one
        // runloop turn, same trick `observeFullScreenFontScaling` uses.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.setFrameAutosaveName(Self.autosaveName)
            // `setFrameAutosaveName` only pulls in previously-saved data if
            // it's set before the window has been given a frame of its own —
            // by the time this view exists, SwiftUI has already shown the
            // window at its default size, so apply any saved frame explicitly.
            window.setFrameUsingName(Self.autosaveName)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
