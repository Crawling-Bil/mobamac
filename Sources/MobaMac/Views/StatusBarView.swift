import SwiftUI
import AppKit

/// The strip along the bottom of the detail column. It answers, at a glance,
/// the four questions that used to need a guess or a trip to Finder: what am
/// I connected to, how long has it been up, where is this session's log going,
/// and is broadcast about to send my keystrokes somewhere else.
///
/// It also replaces the old red broadcast banner, which spent a full row at
/// the top of the window saying "broadcast is ON" and pushed the terminal
/// down every time it appeared.
struct StatusBarView: View {
    @ObservedObject var session: OpenSession
    @EnvironmentObject var sessionManager: SessionManager
    @ObservedObject private var logStatus = LogStatus.shared

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                Text(protocolLabel)
                    .font(.caption.weight(.semibold))
                Text(target)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(stateHelp)

            stateDetail

            Spacer(minLength: 12)

            logWarning
            broadcastIndicator
            logFileButton
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Left side

    private var protocolLabel: String {
        switch session.kind {
        case .ssh: return "SSH"
        // Worth calling out explicitly rather than folding into "SSH": a tab
        // lands here only via the automatic fallback, and SSH-1 is
        // cryptographically broken, so seeing which one you actually got
        // matters.
        case .ssh1: return "SSH-1"
        case .telnet: return "TELNET"
        case .serial: return "SERIAL"
        case .local: return "LOCAL"
        }
    }

    private var target: String {
        switch session.kind {
        case .serial:
            let path = session.profile.serialPortPath ?? ""
            let name = path.isEmpty ? "serial port" : (path as NSString).lastPathComponent
            return "\(name) at \(session.profile.baudRate ?? 9600) baud"
        case .local:
            return "\(NSUserName())@localhost"
        case .ssh, .ssh1, .telnet:
            let hostPort = "\(session.profile.host):\(session.profile.port)"
            let user = session.profile.username
            return user.isEmpty ? hostPort : "\(user)@\(hostPort)"
        }
    }

    private var stateColor: Color {
        guard let issue = session.connectionIssue else { return .green }
        if issue.isHostKeyMismatch { return .yellow }
        if issue.needsPassword || issue.isSessionEnded { return .secondary }
        return .red
    }

    private var stateHelp: String {
        session.connectionIssue == nil
            ? "Connected. The dot turns red when the session drops."
            : "This session is not connected."
    }

    /// Either a live connection timer or, when the tab is in trouble, a short
    /// word for what went wrong. Never both: a duration ticking away under a
    /// dropped connection reads as if it were still up.
    @ViewBuilder
    private var stateDetail: some View {
        if let issue = session.connectionIssue {
            Text(issueLabel(issue))
                .font(.caption)
                .foregroundStyle(stateColor)
        } else if let start = session.connectedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Label(Self.duration(from: start, to: context.date), systemImage: "clock")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help("How long this session has been connected.")
        }
    }

    private func issueLabel(_ issue: SSHConnectionIssue) -> String {
        if issue.needsPassword { return "Password required" }
        if issue.isHostKeyMismatch { return "Host key changed" }
        if issue.isSessionEnded { return "Session ended" }
        return issue.isDisconnection ? "Disconnected" : "Connection failed"
    }

    static func duration(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Right side

    /// Only present while broadcast has targets at all. Red when *this* tab
    /// is one of them, because that is the case where a keystroke typed here
    /// also lands on other devices.
    @ViewBuilder
    private var broadcastIndicator: some View {
        if !sessionManager.broadcastTargetIDs.isEmpty {
            let count = sessionManager.broadcastTargetIDs.count
            let includesThisTab = sessionManager.broadcastTargetIDs.contains(session.id)
            Label("Broadcast \(count)", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.weight(includesThisTab ? .semibold : .regular))
                .foregroundStyle(includesThisTab ? Color.red : Color.secondary)
                .help(
                    includesThisTab
                        ? "Broadcast is on and this tab is one of the \(count) targets, so what you type here is also sent to the others."
                        : "Broadcast is on for \(count) other tab\(count == 1 ? "" : "s"). This tab is not a target."
                )
        }
    }

    /// Shown when the chosen log folder could not be written to and the
    /// default was used instead. It is a note, not an alert: the session
    /// connected fine, and interrupting that with a dialog over a log file
    /// would be the wrong trade.
    @ViewBuilder
    private var logWarning: some View {
        if let warning = logStatus.warning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help("Set a different folder in Settings, under Logging.")
        }
    }

    private var logFileButton: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([session.logger.fileURL])
        } label: {
            Label(session.logger.fileURL.lastPathComponent, systemImage: "doc.text")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.link)
        .help("Everything this session prints is written here. Click to show the file in Finder.")
    }
}
