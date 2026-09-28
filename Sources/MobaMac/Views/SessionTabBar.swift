import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The row of open sessions above the terminal.
///
/// Drawn by hand rather than using `TabView`'s own tab strip, which gives no
/// way to put anything inside a tab: no close button, no connection dot, no
/// middle-click, no reordering. It also parked the tabs in the middle of the
/// toolbar, where they read as a segmented control rather than as tabs.
struct SessionTabBar: View {
    @EnvironmentObject var sessionManager: SessionManager
    /// Which tab is currently being dragged, shared with every tab's drop
    /// delegate so a drop knows what is being moved and where from.
    @State private var draggingID: OpenSession.ID?
    /// Lets the accent underline travel from the old tab to the new one
    /// instead of vanishing from one and appearing under the other.
    @Namespace private var underlineNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(sessionManager.openSessions) { session in
                    // Tab and its divider move as one, so a closing tab does
                    // not leave its divider behind for the length of the fade.
                    HStack(spacing: 0) {
                        SessionTabItem(
                            session: session,
                            isActive: session.id == sessionManager.activeSessionID,
                            underlineNamespace: underlineNamespace
                        )
                        .onDrag {
                            draggingID = session.id
                            return NSItemProvider(object: session.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: TabReorderDropDelegate(
                                target: session,
                                sessionManager: sessionManager,
                                draggingID: $draggingID
                            )
                        )
                        Divider().frame(height: 16)
                    }
                    .transition(tabTransition)
                }
            }
            // Scoped to the tab strip. The panes below change on the same
            // state, and the terminals in them must never animate, so this
            // must not become a withAnimation around the state change.
            .animation(Motion.movement(Motion.standard, reduceMotion: reduceMotion),
                       value: sessionManager.activeSessionID)
            .animation(Motion.movement(Motion.standard, reduceMotion: reduceMotion),
                       value: sessionManager.openSessions.map(\.id))
        }
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// A new tab fades in from slightly to the left; a closing one just
    /// fades, and the tabs after it close the gap.
    private var tabTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: reduceMotion ? 0 : -8)),
            removal: .opacity
        )
    }
}

/// One tab. `@ObservedObject` so the title and the connection issue it shows
/// actually redraw, and hover is local state so hovering one tab doesn't
/// invalidate the whole bar.
private struct SessionTabItem: View {
    @ObservedObject var session: OpenSession
    @EnvironmentObject var sessionManager: SessionManager
    let isActive: Bool
    let underlineNamespace: Namespace.ID
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            ConnectionDot(state: sessionManager.connectionState(for: session.profile.id))
                .help(dotHelp)

            Text(session.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)

            // Always laid out, only faded in on hover: a close button that
            // appears out of nowhere would make every tab jump wider the
            // moment the pointer crosses it, and the tab under the pointer
            // would move out from under it.
            Button {
                sessionManager.requestClose(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .animation(Motion.fade(Motion.hover), value: isHovered)
            .allowsHitTesting(isHovered)
            .help("Close this tab.")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .bottom) {
            // Drawn only under the active tab and matched across tabs, so
            // SwiftUI slides one underline from the old position to the new.
            if isActive {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .matchedGeometryEffect(id: "active-tab-underline", in: underlineNamespace)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { sessionManager.activeSessionID = session.id }
        .overlay { MiddleClickCatcher { sessionManager.requestClose(session) } }
        .help(session.title)
    }

    private var dotHelp: String {
        switch sessionManager.connectionState(for: session.profile.id) {
        case .connected: return "Connected."
        case .connecting: return "Connecting…"
        case .failed: return "This session failed or dropped."
        case .idle: return "Not connected."
        }
    }
}

/// Reorders as the drag passes over a tab, so the row rearranges under the
/// pointer instead of only jumping into place on release.
private struct TabReorderDropDelegate: DropDelegate {
    let target: OpenSession
    let sessionManager: SessionManager
    @Binding var draggingID: OpenSession.ID?

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != target.id else { return }
        guard
            let from = sessionManager.openSessions.firstIndex(where: { $0.id == draggingID }),
            let to = sessionManager.openSessions.firstIndex(where: { $0.id == target.id })
        else { return }
        withAnimation(Motion.movement(Motion.hover)) {
            // `move(fromOffsets:toOffset:)` inserts *before* the offset it is
            // given, so dragging rightwards needs one extra to land after the
            // tab being crossed rather than swapping back and forth with it.
            sessionManager.moveSession(from: from, to: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }

    func dropExited(info: DropInfo) {}
}

/// SwiftUI has no middle-click gesture, so this is a transparent AppKit view
/// laid over a tab that answers hit-testing only for the middle button.
/// Everything else — the click that selects the tab, the close button, hover
/// — falls straight through to the SwiftUI views underneath.
private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        CatcherView(action: action)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.action = action
    }

    private final class CatcherView: NSView {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("MiddleClickCatcher is never loaded from a nib")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                return super.hitTest(point) == nil ? nil : self
            default:
                return nil
            }
        }

        override func otherMouseDown(with event: NSEvent) {
            // Swallowed on purpose: AppKit only delivers the matching mouse-up
            // to the view that accepted the mouse-down.
        }

        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2 else {
                super.otherMouseUp(with: event)
                return
            }
            action()
        }
    }
}
