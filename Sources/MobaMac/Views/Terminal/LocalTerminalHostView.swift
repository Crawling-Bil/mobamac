import SwiftUI
import SwiftTerm
import AppKit

/// Subclass of LocalProcessTerminalView that also tees every raw byte the
/// local shell's PTY produces to our own session log file. `dataReceived`
/// is confirmed `open` in the resolved SwiftTerm package (Mac/MacLocalTerminalView.swift)
/// — overriding it here is the direct hook, no external process needed.
///
/// This replaces the previous design, which ran `/usr/bin/script` inside
/// the PTY to get a byte-for-byte tee "for free" at the OS level. That
/// worked for logging, but macOS's `/usr/bin/script` doesn't forward
/// window-resize (SIGWINCH) to the shell it wraps — a historically-missing
/// feature in BSD script implementations (FreeBSD only patched their own
/// script(1) for this recently; Apple's fork predates that fix). The
/// practical symptom: resizing the MobaMac window — especially entering
/// full screen — never reached the actual zsh/bash process, so anything
/// that sizes itself off the terminal width (e.g. a Starship/P10k
/// right-side prompt segment) stayed frozen at the old width instead of
/// sliding over. Talking to LocalProcess directly removes that extra PTY
/// hop, so the normal resize -> sizeChanged -> pty TIOCSWINSZ path
/// (already used correctly by the SSH and Raw host views) reaches the
/// shell here too.
final class LoggingLocalProcessTerminalView: LocalProcessTerminalView {
    var onRawData: ((Data) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onRawData?(Data(slice))
        super.dataReceived(slice: slice)
    }

    // Repeated from MobaMacTerminalView rather than shared by inheritance:
    // this class has to descend from LocalProcessTerminalView, so the two
    // can't have a common terminal subclass. The behaviour itself lives in
    // TerminalInteraction, which is what actually keeps them identical.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        TerminalInteraction.copySelectionIfEnabled(in: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard TerminalInteraction.handleRightClickPaste(event, in: self) else {
            super.rightMouseDown(with: event)
            return
        }
    }
}

/// For the "Local Terminal" tab.
struct LocalTerminalHostView: NSViewRepresentable {
    let openSession: OpenSession

    func makeNSView(context: Context) -> LoggingLocalProcessTerminalView {
        let view = LoggingLocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 800, height: 500))
        view.apply(theme: TerminalTheme.theme(for: openSession.themeID))
        view.applyMobaMacTerminalFont()
        view.observeFullScreenFontScaling()
        openSession.terminalView = view
        view.onRawData = { [weak openSession] data in
            openSession?.logger.write(data)
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        view.startProcess(executable: shell)
        return view
    }

    func updateNSView(_ nsView: LoggingLocalProcessTerminalView, context: Context) {}
}
