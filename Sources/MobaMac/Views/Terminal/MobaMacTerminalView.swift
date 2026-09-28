import AppKit
import SwiftTerm

/// The TerminalView used by SSH, SSH-1, Telnet and Serial tabs.
///
/// Exists only to carry the two optional mouse habits. The local-terminal tab
/// can't use this class — it needs `LocalProcessTerminalView` as its base —
/// so both subclasses call into `TerminalInteraction` rather than
/// reimplementing anything.
final class MobaMacTerminalView: TerminalView, NSServicesMenuRequestor {
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

    // MARK: - Services

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        TerminalInteraction.servicesRequestor(sendType: sendType, returnType: returnType, in: self)
            ?? super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    // Not an override: NSView does not declare this, it comes from
    // NSServicesMenuRequestor, which this class now conforms to.
    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        TerminalInteraction.writeSelection(to: pboard, in: self)
    }
}
