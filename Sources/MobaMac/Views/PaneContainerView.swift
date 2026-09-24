import SwiftUI
import AppKit

/// Lays every open session out into pane rectangles.
///
/// The one thing that decides this design: in SwiftUI, moving a view from
/// one container to another destroys it and builds a new one. A terminal is
/// an AppKit view holding its own scrollback, so putting each pane in its own
/// HSplitView branch would throw away everything a session had printed the
/// moment it moved between panes, or between a pane and a hidden tab.
///
/// So there is one flat ZStack holding every session, exactly as the plain
/// tab view did, and panes are made by giving each session the frame of the
/// pane it belongs to. Identity never changes, so nothing is rebuilt.
/// Sessions not on screen keep their view at full size with zero opacity,
/// which is what already kept scrollback alive across tab switches.
///
/// Sizing follows from that for free. Each pane hands its session a real
/// frame, SwiftTerm recomputes its rows and columns from that frame and
/// reports them through `resize(cols:rows:)`, so every device is told the
/// size of the pane it is actually being shown in. Dragging a divider
/// changes the frames, so the same path runs again.
struct PaneContainerView: View {
    @EnvironmentObject var sessionManager: SessionManager

    private static let dividerHitWidth: CGFloat = 8
    private static let minimumFraction: CGFloat = 0.15

    var body: some View {
        GeometryReader { geometry in
            let layout = sessionManager.paneLayout
            let rects = Self.paneRects(
                layout: layout,
                size: geometry.size,
                fractionX: sessionManager.splitFractionX,
                fractionY: sessionManager.splitFractionY
            )

            ZStack(alignment: .topLeading) {
                terminals(rects: rects, fullSize: geometry.size)
                if layout != .single {
                    paneChrome(layout: layout, rects: rects)
                    dividers(layout: layout, size: geometry.size)
                }
            }
            .coordinateSpace(name: "panes")
        }
    }

    // MARK: - Terminals

    private func terminals(rects: [CGRect], fullSize: CGSize) -> some View {
        ForEach(sessionManager.openSessions) { session in
            let paneIndex = sessionManager.paneIndex(of: session.id)
            let rect = paneIndex.map { rects[$0] } ?? CGRect(origin: .zero, size: fullSize)
            SessionTabView(session: session)
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .offset(x: rect.minX, y: rect.minY)
                .opacity(paneIndex == nil ? 0 : 1)
                .allowsHitTesting(paneIndex != nil)
                .zIndex(paneIndex == nil ? 0 : 1)
                // Simultaneous, so clicking still reaches the terminal for
                // placing the cursor and selecting text. A tap only fires
                // when the pointer did not drag, so selection is untouched.
                .simultaneousGesture(TapGesture().onEnded {
                    if let paneIndex { sessionManager.focusPane(paneIndex) }
                })
        }
    }

    // MARK: - Pane chrome

    private func paneChrome(layout: SessionManager.PaneLayout, rects: [CGRect]) -> some View {
        ForEach(0..<layout.paneCount, id: \.self) { index in
            let rect = rects[index]
            ZStack(alignment: .topTrailing) {
                Rectangle()
                    .strokeBorder(
                        index == sessionManager.focusedPaneIndex ? Color.accentColor : Color.clear,
                        lineWidth: 2
                    )
                    // Otherwise the border would swallow every click meant
                    // for the terminal underneath it.
                    .allowsHitTesting(false)

                sessionPicker(for: index)
                    .padding(6)
            }
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .offset(x: rect.minX, y: rect.minY)
            .zIndex(2)
        }
    }

    private func sessionPicker(for index: Int) -> some View {
        Menu {
            Button("None") {
                sessionManager.assignSession(nil, toPane: index)
            }
            Divider()
            ForEach(sessionManager.openSessions) { session in
                Button(session.title) {
                    sessionManager.assignSession(session.id, toPane: index)
                }
            }
        } label: {
            Text(paneTitle(index))
                .font(.caption2)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which session this pane shows.")
    }

    private func paneTitle(_ index: Int) -> String {
        guard let id = sessionManager.paneSessionIDs[index],
              let session = sessionManager.openSessions.first(where: { $0.id == id })
        else { return "Empty" }
        return session.title
    }

    // MARK: - Dividers

    private func dividers(layout: SessionManager.PaneLayout, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if layout == .splitHorizontally || layout == .grid {
                dividerHandle(vertical: true, size: size)
            }
            if layout == .splitVertically || layout == .grid {
                dividerHandle(vertical: false, size: size)
            }
        }
        .zIndex(3)
    }

    private func dividerHandle(vertical: Bool, size: CGSize) -> some View {
        let fraction = vertical ? sessionManager.splitFractionX : sessionManager.splitFractionY
        let span = vertical ? size.width : size.height
        return Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(
                width: vertical ? 1 : size.width,
                height: vertical ? size.height : 1
            )
            .frame(
                width: vertical ? Self.dividerHitWidth : size.width,
                height: vertical ? size.height : Self.dividerHitWidth
            )
            .contentShape(Rectangle())
            .offset(
                x: vertical ? span * fraction - Self.dividerHitWidth / 2 : 0,
                y: vertical ? 0 : span * fraction - Self.dividerHitWidth / 2
            )
            .onHover { inside in
                if inside {
                    vertical ? NSCursor.resizeLeftRight.push() : NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .named("panes"))
                    .onChanged { value in
                        let raw = (vertical ? value.location.x : value.location.y) / max(span, 1)
                        let clamped = min(max(raw, Self.minimumFraction), 1 - Self.minimumFraction)
                        if vertical {
                            sessionManager.splitFractionX = clamped
                        } else {
                            sessionManager.splitFractionY = clamped
                        }
                    }
            )
    }

    // MARK: - Geometry

    /// Always four rectangles. Unused slots come back empty rather than nil,
    /// so callers never index past the end.
    static func paneRects(
        layout: SessionManager.PaneLayout,
        size: CGSize,
        fractionX: CGFloat,
        fractionY: CGFloat
    ) -> [CGRect] {
        let full = CGRect(origin: .zero, size: size)
        let splitX = (size.width * fractionX).rounded()
        let splitY = (size.height * fractionY).rounded()

        switch layout {
        case .single:
            return [full, .zero, .zero, .zero]
        case .splitHorizontally:
            return [
                CGRect(x: 0, y: 0, width: splitX, height: size.height),
                CGRect(x: splitX, y: 0, width: size.width - splitX, height: size.height),
                .zero, .zero
            ]
        case .splitVertically:
            return [
                CGRect(x: 0, y: 0, width: size.width, height: splitY),
                CGRect(x: 0, y: splitY, width: size.width, height: size.height - splitY),
                .zero, .zero
            ]
        case .grid:
            let rightWidth = size.width - splitX
            let bottomHeight = size.height - splitY
            return [
                CGRect(x: 0, y: 0, width: splitX, height: splitY),
                CGRect(x: splitX, y: 0, width: rightWidth, height: splitY),
                CGRect(x: 0, y: splitY, width: splitX, height: bottomHeight),
                CGRect(x: splitX, y: splitY, width: rightWidth, height: bottomHeight)
            ]
        }
    }
}
