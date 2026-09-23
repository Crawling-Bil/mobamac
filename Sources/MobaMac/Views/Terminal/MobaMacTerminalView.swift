import AppKit
import SwiftTerm

/// The TerminalView used by SSH, SSH-1, Telnet and Serial tabs.
///
/// Exists only to carry the two optional mouse habits. The local-terminal tab
/// can't use this class — it needs `LocalProcessTerminalView` as its base —
/// so both subclasses call into `TerminalInteraction` rather than
/// reimplementing anything.
final class MobaMacTerminalView: TerminalView {
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
