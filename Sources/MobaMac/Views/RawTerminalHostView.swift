import SwiftUI
import SwiftTerm
import AppKit

/// Bridges a bare SwiftTerm.TerminalView to any non-SSH ConnectionSession
/// — Telnet, Serial. Deliberately no multi-exec/broadcast wiring here:
/// that's an SSH-specific feature (see SSHTerminalHostView) that doesn't
/// map cleanly onto a console port or a legacy Telnet session, so this
/// stays a plain one-to-one bridge.
struct RawTerminalHostView: NSViewRepresentable {
    let openSession: OpenSession
    let connection: ConnectionSession

    func makeNSView(context: Context) -> TerminalView {
        let terminalView = TerminalView(frame: .init(x: 0, y: 0, width: 800, height: 500))
        terminalView.terminalDelegate = context.coordinator
        terminalView.apply(theme: TerminalTheme.theme(for: openSession.themeID))
        terminalView.applyMobaMacTerminalFont()
        terminalView.observeFullScreenFontScaling()
        openSession.terminalView = terminalView

        connection.onOutput = { [weak terminalView] data in
            DispatchQueue.main.async {
                terminalView?.feed(byteArray: [UInt8](data)[...])
            }
            openSession.logger.write(data)
        }

        return terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(connection: connection)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let connection: ConnectionSession

        init(connection: ConnectionSession) {
            self.connection = connection
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let payload = Data(data)
            // UI spec §9.3: same multi-line paste confirmation as the SSH
            // host view — a Telnet or Serial console is just as exposed to
            // an accidental multi-command paste as an SSH session is.
            guard MultiLinePasteGuard.shouldSend(payload) else { return }
            Task { await connection.send(payload) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { await connection.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
