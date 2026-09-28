import SwiftUI
import AppKit

/// One place to type a command for every broadcast target at once.
///
/// Typing into one tab and having it copied to the others works, but with
/// several panes on screen it is unclear which terminal you are typing into
/// and easy to pick the wrong one. This bar belongs to none of them.
///
/// It exists only while broadcast has targets. A disabled bar would only
/// take height from the terminal, and its absence is itself a signal.
struct BroadcastInputBar: View {
    @EnvironmentObject var sessionManager: SessionManager
    @State private var text = ""

    private var targetCount: Int { sessionManager.broadcastTargetIDs.count }

    private var placeholder: String {
        targetCount == 1 ? "Send to 1 session" : "Send to \(targetCount) sessions"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(Color.red)
                .help("Broadcast input. Commands typed here go to every broadcast target.")

            BroadcastCommandField(
                text: $text,
                placeholder: placeholder,
                history: sessionManager.broadcastInputHistory,
                onSubmit: submit,
                onEscape: returnFocusToTerminal
            )
            // Fixed, so a pasted multi-line text never makes the bar taller
            // and resizes the terminals above it.
            .frame(height: 18)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // Red, because this field is not like the others: one Return
            // here reaches several devices.
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.red.opacity(0.8), lineWidth: 1)
            )
            .help("Return sends to every connected target. Up and Down recall earlier commands. Esc goes back to the terminal.")

            Button("Send", action: submit)
                .buttonStyle(PressableBarButtonStyle())
                .font(.caption)
                .help("Send to every connected broadcast target.")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .appearMotion(duration: Motion.standard)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func submit() {
        if sessionManager.sendFromBroadcastInput(text) {
            text = ""
        }
    }

    private func returnFocusToTerminal() {
        guard let session = sessionManager.focusedSession else { return }
        sessionManager.focusTerminal(of: session)
    }
}

/// An AppKit text field rather than SwiftUI's, for three things SwiftUI's
/// does not give reliably: Up and Down for history, Esc handled by the field
/// rather than the window, and pasted line breaks kept as line breaks so
/// MultiLinePasteGuard can see them instead of lines silently run together.
private struct BroadcastCommandField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let history: [String]
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> BroadcastCommandTextField {
        let field = BroadcastCommandTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = false
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = placeholder
        field.setAccessibilityLabel("Broadcast command")
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: BroadcastCommandTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BroadcastCommandField
        /// Where Up and Down have got to in the history, nil while editing
        /// fresh text.
        private var historyIndex: Int?
        /// What was being typed before Up was first pressed, given back when
        /// Down goes past the newest entry.
        private var draft = ""

        init(parent: BroadcastCommandField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            historyIndex = nil
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                historyIndex = nil
                return true
            case #selector(NSResponder.moveUp(_:)):
                recall(older: true, in: textView)
                return true
            case #selector(NSResponder.moveDown(_:)):
                recall(older: false, in: textView)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }

        private func recall(older: Bool, in textView: NSTextView) {
            let history = parent.history
            guard !history.isEmpty else { return }
            let next: Int?
            if older {
                if let historyIndex {
                    next = max(0, historyIndex - 1)
                } else {
                    draft = textView.string
                    next = history.count - 1
                }
            } else {
                guard let historyIndex else { return }
                next = historyIndex + 1 < history.count ? historyIndex + 1 : nil
            }
            historyIndex = next
            let value = next.map { history[$0] } ?? draft
            textView.string = value
            textView.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
            parent.text = value
        }
    }
}

/// Takes focus when View > Focus Broadcast Input is chosen.
final class BroadcastCommandTextField: NSTextField {
    private var focusObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, focusObserver == nil else { return }
        focusObserver = NotificationCenter.default.addObserver(
            forName: .focusBroadcastInput,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    deinit {
        if let focusObserver {
            NotificationCenter.default.removeObserver(focusObserver)
        }
    }
}
