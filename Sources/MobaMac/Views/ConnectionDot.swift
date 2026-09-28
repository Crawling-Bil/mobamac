import SwiftUI

/// The connection-state dot used in the sidebar, the tab bar and the status
/// bar, so all three change colour and pulse the same way.
///
/// One shape whose colours change, rather than a different view per state:
/// swapping views gives SwiftUI nothing to animate between, so the colour
/// would jump instead of easing.
///
/// While connecting it pulses. That is also the only sign the app is doing
/// something during a slow handshake, so it stops the moment the state
/// leaves connecting, in either direction.
struct ConnectionDot: View {
    let color: Color
    /// Outline only, for a saved session that is not connected.
    var hollow = false
    var pulsing = false
    var size: CGFloat = 7

    var body: some View {
        // Paused unless pulsing, so an idle dot costs nothing per frame.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !pulsing)) { context in
            Circle()
                .fill(hollow ? Color.clear : color)
                .overlay(Circle().stroke(color, lineWidth: hollow ? 1 : 0))
                .frame(width: size, height: size)
                .opacity(pulsing
                    ? Motion.pulseOpacity(
                        at: context.date,
                        period: Motion.connectingPulsePeriod,
                        low: Motion.connectingPulseLow
                    )
                    : 1)
        }
        .animation(Motion.fade(Motion.colorChange), value: color)
        .animation(Motion.fade(Motion.colorChange), value: hollow)
        .animation(Motion.fade(Motion.colorChange), value: pulsing)
    }
}

extension ConnectionDot {
    init(state: SessionManager.ConnectionState, size: CGFloat = 7) {
        switch state {
        case .idle:
            self.init(color: .secondary, hollow: true, size: size)
        case .connecting:
            self.init(color: .yellow, pulsing: true, size: size)
        case .connected:
            self.init(color: .green, size: size)
        case .failed:
            self.init(color: .red, size: size)
        }
    }
}
