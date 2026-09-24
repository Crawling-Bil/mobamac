import SwiftUI
import SwiftTerm
import AppKit

/// Bridges a bare SwiftTerm.TerminalView to an SSHConnectionSession: bytes
/// coming FROM the shell get fed into the view for rendering (and teed to
/// the session's log file); keystrokes typed INTO the view get sent back
/// down the SSH channel — or, if this tab is one of
/// SessionManager.broadcastTargetIDs, down every other opted-in SSH channel
/// too (multi-exec).
///
/// NOTE: TerminalViewDelegate's exact required methods have shifted a bit
/// across SwiftTerm versions. If Xcode flags missing/extra requirements
/// here once packages resolve, adjust the Coordinator's method list to
/// match — `send` and `sizeChanged` are the two that actually matter for
/// this app to function; the rest are no-ops you can safely leave empty.
struct SSHTerminalHostView: NSViewRepresentable {
    let openSession: OpenSession
    let ssh: SSHConnectionSession
    @EnvironmentObject var sessionManager: SessionManager

    func makeNSView(context: Context) -> TerminalView {
        let terminalView = MobaMacTerminalView(frame: .init(x: 0, y: 0, width: 800, height: 500))
        terminalView.terminalDelegate = context.coordinator
        terminalView.apply(theme: TerminalTheme.theme(for: openSession.themeID))
        terminalView.applyMobaMacTerminalFont()
        terminalView.observeFullScreenFontScaling()
        openSession.terminalView = terminalView

        ssh.onOutput = { [weak openSession, weak terminalView] data in
            // The logger always tees the raw, unmodified bytes the device
            // actually sent — regardless of the highlighting toggle below.
            // A session log should never contain ANSI codes MobaMac injected
            // itself; that would make the log lie about what the device sent.
            openSession?.logger.write(data)
            // Same callback, so the startup runner sees exactly what the
            // device sent and can tell when it has gone quiet.
            openSession?.startupRunner?.noteOutput(data)

            DispatchQueue.main.async {
                guard let openSession else { return }
                if openSession.highlightingEnabled {
                    // Highlighting needs complete lines to run its regexes
                    // against, so this buffers until a newline shows up —
                    // trading latency (including the user's own echo) for
                    // readability. That trade-off is exactly why this path
                    // only runs when the per-session toggle is on.
                    let lines = openSession.lineBuffer.append(data)
                    for line in lines {
                        terminalView?.feed(text: line + "\r\n")
                    }
                } else {
                    terminalView?.feed(byteArray: [UInt8](data)[...])
                }
            }
        }

        return terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(ssh: ssh, sessionID: openSession.id, sessionManager: sessionManager)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let ssh: SSHConnectionSession
        let sessionID: OpenSession.ID
        let sessionManager: SessionManager

        init(ssh: SSHConnectionSession, sessionID: OpenSession.ID, sessionManager: SessionManager) {
            self.ssh = ssh
            self.sessionID = sessionID
            self.sessionManager = sessionManager
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let payload = Data(data)
            // UI spec §9.3: a burst of bytes containing more than one line
            // is a paste, not typing (a real keystroke — Enter included —
            // always arrives as its own separate `send` call), so confirm
            // before firing what could be several unintended commands in a
            // row at the device on the other end of this session.
            guard MultiLinePasteGuard.shouldSend(payload) else { return }
            // Only a tab the user has explicitly opted into broadcast (via
            // the Broadcast popover) replicates its keystrokes elsewhere —
            // every other tab behaves exactly like a normal, un-broadcast
            // session even while broadcast is "on" for others. This is the
            // safety fix from the UI spec: no more all-or-nothing multi-exec.
            if sessionManager.broadcastTargetIDs.contains(sessionID) {
                sessionManager.broadcast(payload, from: sessionID)
            } else {
                Task { await ssh.send(payload) }
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { await ssh.resize(cols: newCols, rows: newRows) }
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
