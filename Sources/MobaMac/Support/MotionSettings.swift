import SwiftUI
import AppKit

/// Every duration and curve the app animates with, in one place, so the
/// motion stays consistent and can be retuned without a search across files.
///
/// Three rules sit behind every use of this:
///
/// 1. Nothing inside a terminal is ever animated. Device output appears the
///    instant it arrives. Neither is the terminal's size: every intermediate
///    size of an animated resize is a real row and column count that
///    SwiftTerm reports to the device through `resize(cols:rows:)`, so a
///    sliding panel would send the device a burst of window changes. Where
///    something opens beside or above a terminal, the layout changes in one
///    step and only the new element's own content fades or slides in, as a
///    render-time offset that does not move anything else.
///
/// 2. Reduce Motion turns off everything that moves or reflows. Fades and
///    colour changes stay, since they change how something looks rather than
///    where it is. That split is what `movement` and `fade` encode.
///
/// 3. Animations are attached to the specific value that changed, never
///    wholesale to a list, so a sidebar with dozens of sessions does not
///    pay to animate rows that did not change.
enum Motion {
    /// Hover reveals: the actions button on a sidebar row.
    static let hover: Double = 0.15
    /// A sidebar row's hover background.
    static let rowHover: Double = 0.12
    /// Folders opening, the chevron turning, the tab underline moving, the
    /// connection problem screen.
    static let standard: Double = 0.2
    /// Side panel content.
    static let panel: Double = 0.22
    static let findBarIn: Double = 0.18
    static let findBarOut: Double = 0.15
    /// Status dot colour changes.
    static let colorChange: Double = 0.25
    /// Button press feedback.
    static let press: Double = 0.1

    static let connectingPulsePeriod: Double = 1.2
    static let connectingPulseLow: Double = 0.4
    /// Slower and shallower than the connecting pulse: broadcast being on is
    /// a standing condition to notice, not activity to watch.
    static let broadcastPulsePeriod: Double = 2.4
    static let broadcastPulseLow: Double = 0.65

    /// The system setting, for code with no view environment to read. Views
    /// read `\.accessibilityReduceMotion` instead, which updates live.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// For anything that moves or reflows. Nil under Reduce Motion, which
    /// makes the change happen at once instead of sliding.
    static func movement(_ duration: Double, reduceMotion: Bool = Motion.reduceMotion) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }

    /// For fades and colour changes, which Reduce Motion leaves alone.
    static func fade(_ duration: Double) -> Animation {
        .easeInOut(duration: duration)
    }

    /// Opacity for a continuous pulse, as a function of time rather than of
    /// state. Driven by a paused-when-idle TimelineView, it stops the instant
    /// the pulse is no longer wanted instead of finishing a cycle or getting
    /// stuck half-transparent, which is what a repeating SwiftUI animation
    /// does when the state behind it changes mid-cycle.
    static func pulseOpacity(at date: Date, period: Double, low: Double) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let phase = (sin(t * 2 * .pi / period) + 1) / 2
        return low + (1 - low) * phase
    }
}

/// Fades a view in, optionally sliding it a short way, when it first
/// appears. The slide is an offset, which moves the pixels without moving
/// the layout, so the element can take its full place at once while only
/// its contents animate. See rule 1 above.
private struct AppearMotion: ViewModifier {
    let duration: Double
    let offset: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(shown || reduceMotion ? .zero : offset)
            .onAppear {
                withAnimation(.easeOut(duration: duration)) { shown = true }
            }
    }
}

extension View {
    func appearMotion(duration: Double, from offset: CGSize = .zero) -> some View {
        modifier(AppearMotion(duration: duration, offset: offset))
    }
}

/// A compact bordered button that gives a small press response.
///
/// Used for the button bar rather than the toolbar. Toolbar buttons are
/// drawn by AppKit's NSToolbar and already have the system's own press
/// highlight; a custom style there would replace the native bezel with an
/// imitation of it.
struct PressableBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBarButtonBody(configuration: configuration)
    }
}

/// Named apart from `ButtonStyle.Body` on purpose: a nested type called
/// `Body` is taken by the compiler as the protocol's associated type.
private struct PressableBarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: Motion.press), value: configuration.isPressed)
    }
}
