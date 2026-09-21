import Foundation
import SwiftUI
import SwiftTerm
import AppKit
import NIO
import NIOSSH

enum OpenSessionKind {
    case ssh(SSHConnectionSession)
    /// Automatic fallback used when a device only speaks SSH-1 (Citadel/
    /// swift-nio-ssh refuse the handshake with `.unsupportedVersion`) --
    /// see `SessionManager.openSSH` and `SSH1ConnectionSession`.
    case ssh1(SSH1ConnectionSession)
    case telnet(TelnetConnectionSession)
    case serial(SerialConnectionSession)
    case local // handled directly by LocalProcessTerminalView, no ConnectionSession needed
}

/// A connection failure or security warning surfaced in place of the
/// terminal for that tab — e.g. a rejected host key, a bad private key, a
/// serial port that couldn't be opened, or any other error a
/// ConnectionSession's `start()` threw. Previously these were swallowed
/// (`try? await ssh.start()`), which is exactly how a bad host or a
/// host-key mismatch turned into a tab that just sat there blank forever
/// with no explanation.
struct SSHConnectionIssue {
    let message: String
    let isHostKeyMismatch: Bool
    /// True when this tab connected successfully at some point and then
    /// dropped (network blip, device reboot, idle timeout despite
    /// keepalive) rather than never having connected at all. Drives whether
    /// the "Reconnect" button (UI spec §9.2) is offered: a session that was
    /// fine and dropped gets "Reconnect", while a failure that never
    /// connected at all gets "Try Again" instead: some of those are
    /// permanent (bad host, wrong credentials) but plenty are not (the
    /// device was out of SSH sessions, a handshake timed out), and making
    /// someone close the tab and walk back through the sidebar to retry
    /// one of those is worse than offering a button that sometimes fails
    /// again. A host-key mismatch keeps its own distinct recovery path.
    let isDisconnection: Bool
}

/// One open tab: pairs a profile with its live connection (if any) and its logger.
final class OpenSession: ObservableObject, Identifiable {
    let id = UUID()
    let profile: SessionProfile
    /// Mutable (not `let`) so reconnect (UI spec §9.2) can swap in a brand
    /// new `ConnectionSession` for the same tab instead of opening a second
    /// one — `SessionTabView`'s `switch session.kind` re-renders the right
    /// host view automatically the moment this changes, and the terminal
    /// visuals never need touching directly.
    @Published var kind: OpenSessionKind
    /// Mutable so each reconnect attempt gets its own fresh, timestamped log
    /// file rather than appending a new connection's output to the previous
    /// attempt's log — safe to swap because host views always read
    /// `openSession.logger` dynamically per write, never a captured local.
    var logger: SessionLogger
    @Published var title: String
    @Published var connectionIssue: SSHConnectionIssue?
    /// 0 while idle; set while an auto-reconnect loop (UI spec §9.2) is
    /// actively retrying, so the UI can show "Reconnecting… N/20".
    @Published var reconnectAttempt: Int = 0
    /// Per-session, default-off syntax-highlighting toggle (UI spec §6). Off
    /// by default because highlighting requires buffering a full line before
    /// anything reaches the screen — including the user's own typed-character
    /// echo — which is a real latency cost most sessions shouldn't pay.
    @Published var highlightingEnabled: Bool = false
    /// Backs `highlightingEnabled` when it's on — buffers raw bytes into
    /// complete lines before they're colorized and fed to the terminal view.
    /// Lives here (not as a local in the host view) so it survives across
    /// however many `onOutput` callbacks fire for this session's lifetime.
    let lineBuffer = LineBuffer()
    /// Set by whichever host view (SSHTerminalHostView / RawTerminalHostView /
    /// LocalTerminalHostView) actually creates the SwiftTerm.TerminalView for
    /// this tab, so snippets/macros can reach it — `TerminalView.send(txt:)`
    /// is the same public entry point a real keystroke goes through, so
    /// firing a snippet works uniformly across every session kind. Weak
    /// because the view owns its lifecycle, not this object.
    weak var terminalView: TerminalView?
    /// Backs the toolbar's live theme picker (UI spec follow-up: pick a
    /// theme for the active tab without going through Edit Session). Separate
    /// from `profile.themeID`, which is immutable on this object and only
    /// describes what a fresh tab starts from; changing this re-colors the
    /// already-running TerminalView immediately (SessionTabView's `onChange`
    /// does the actual `apply(theme:)` call) and ContentView persists it back
    /// to the saved profile so the next tab opened from it starts the same way.
    @Published var themeID: String

    init(profile: SessionProfile, kind: OpenSessionKind, logger: SessionLogger) {
        self.profile = profile
        self.kind = kind
        self.logger = logger
        self.title = profile.name
        self.themeID = profile.themeID ?? TerminalTheme.appDefault.id
    }
}

/// Single source of truth for which tabs are open and which one is active.
/// ProfileStore holds what CAN be opened; this holds what IS currently open.
///
/// Deliberately not wiring `onOutput` here — the terminal host views
/// (SSHTerminalHostView / RawTerminalHostView / LocalTerminalHostView) own
/// that, since feeding bytes into a SwiftTerm.TerminalView has to happen on
/// the main thread right where the view lives.
final class SessionManager: ObservableObject {
    /// Per-profile connection state, shown as a status dot in the sidebar —
    /// including for profiles that aren't in an open tab at all (those just
    /// read as `.idle`, the default for anything not in this dictionary).
    enum ConnectionState {
        case idle       // saved, not connected — gray outline dot
        case connecting // yellow dot
        case connected  // green dot
        case failed     // red dot
    }

    @Published var openSessions: [OpenSession] = []
    @Published var activeSessionID: OpenSession.ID?
    @Published private var connectionStates: [UUID: ConnectionState] = [:]

    /// Set once from MobaMacApp/ContentView so `openSSH` (and friends) can
    /// update `lastConnectedAt` on the underlying saved profile when a
    /// connection succeeds. Weak since ProfileStore, not this, owns that
    /// object's lifetime.
    weak var profileStore: ProfileStore?

    /// Set once from ContentView, same as `profileStore` — lets `openSSH`
    /// and reconnect resolve a profile's `credentialSetID` (UI spec §9.4)
    /// into an actual username/secret at connect time. Weak for the same
    /// reason: CredentialSetStore, not this, owns that object's lifetime.
    weak var credentialSetStore: CredentialSetStore?

    /// The set of open SSH tabs that currently share keystrokes with each
    /// other (MobaXterm calls the underlying feature "multi-exec"). Replaces
    /// the old all-or-nothing `broadcastEnabled: Bool` — see the UI spec's
    /// broadcast-scoping section. Empty means broadcast is effectively off;
    /// a tab not in this set behaves normally even while other tabs are
    /// broadcasting to each other.
    @Published var broadcastTargetIDs: Set<OpenSession.ID> = []

    /// Toggled by the ⌘, menu-bar shortcut wired in MobaMacApp (same
    /// "menu key equivalents beat the first responder" trick already used
    /// for macro shortcuts) — lives here rather than as local ContentView
    /// state so a global keystroke can reach it without a screen tap first.
    @Published var showingCommandPalette: Bool = false

    /// One in-flight reconnect (manual retry or auto-reconnect loop) per
    /// tab, keyed by `OpenSession.id`. Tracked here rather than on
    /// `OpenSession` itself so closing a tab can cancel its loop with no
    /// extra bookkeeping on the session object. A manual reconnect cancels
    /// whatever's already running for that tab before starting its own, so
    /// there's never more than one attempt racing another for the same tab.
    private var reconnectTasks: [OpenSession.ID: Task<Void, Never>] = [:]

    /// Read by ContentView's "Reconnecting… x/y" label too, so the
    /// number a user sees always matches the number actually used.
    static let maxAutoReconnectAttempts = 20
    private static let autoReconnectDelaySeconds: UInt64 = 15

    var activeSession: OpenSession? {
        openSessions.first { $0.id == activeSessionID }
    }

    private static func isSSHKind(_ kind: OpenSessionKind) -> Bool {
        switch kind {
        case .ssh, .ssh1:
            return true
        case .telnet, .serial, .local:
            return false
        }
    }

    var openSSHSessionCount: Int {
        openSessions.filter { Self.isSSHKind($0.kind) }.count
    }

    var openSSHSessions: [OpenSession] {
        openSessions.filter { Self.isSSHKind($0.kind) }
    }

    func connectionState(for profileID: UUID) -> ConnectionState {
        connectionStates[profileID] ?? .idle
    }

    /// Sends the same bytes to every open SSH session that's currently opted
    /// into broadcast. Includes the session that originated the keystroke —
    /// it already rendered locally in that session's own TerminalView, this
    /// just replicates the same input to the others that are in scope.
    func broadcast(_ data: Data, from senderID: OpenSession.ID) {
        for session in openSessions {
            guard broadcastTargetIDs.contains(session.id) else { continue }
            switch session.kind {
            case .ssh(let ssh):
                Task { await ssh.send(data) }
            case .ssh1(let ssh1):
                Task { await ssh1.send(data) }
            default:
                continue
            }
        }
    }

    func closeActive() {
        guard let active = activeSession else { return }
        close(active)
    }

    /// Fires a snippet/macro at the active tab, whatever kind it is — SSH,
    /// Telnet, Serial or Local all end up feeding the same
    /// `TerminalView.send(txt:)` entry point a real keystroke would use, so
    /// there's no session-kind-specific plumbing needed here.
    func sendToActive(_ text: String) {
        guard let view = activeSession?.terminalView else { return }
        view.send(txt: text)
    }

    /// UI spec: font-size defaults / ⌘+⌘-⌘0 zoom (MobaMacApp's "View" menu).
    /// Pushes `size` — the new persisted "normal" point size — live to
    /// every open tab's terminal at once, respecting whichever tab happens
    /// to already be in native full screen: every tab shares one window, so
    /// full screen is an all-or-nothing state for this app, not a per-tab
    /// one, and a tab currently in full screen should keep looking bumped
    /// up by `TerminalFontSettings.fullScreenBump` rather than snapping back
    /// to the windowed size mid-zoom.
    func applyTerminalFontSize(_ size: CGFloat) {
        for session in openSessions {
            guard let view = session.terminalView else { continue }
            let isFullScreen = view.window?.styleMask.contains(.fullScreen) ?? false
            view.applyMobaMacTerminalFont(size: isFullScreen ? size + TerminalFontSettings.fullScreenBump : size)
        }
    }

    /// If `profile.credentialSetID` points at a saved credential set (UI
    /// spec §9.4), returns a copy of `profile` with its username/auth
    /// method/key path overridden from that set, plus that set's own
    /// Keychain secret — so the rest of the connect path (and reconnect,
    /// which calls this too) never needs to know credential sets exist.
    /// Falls back to `profile`/`fallbackSecret` untouched when there's no
    /// credential set referenced, or it's since been deleted.
    private func resolvedSSHCredentials(for profile: SessionProfile, fallbackSecret: String?) -> (profile: SessionProfile, secret: String?) {
        guard let credentialSetID = profile.credentialSetID,
              let set = credentialSetStore?.credentialSet(id: credentialSetID) else {
            return (profile, fallbackSecret)
        }
        var resolved = profile
        resolved.username = set.username
        resolved.authMethod = set.authMethod
        resolved.privateKeyPath = set.privateKeyPath
        return (resolved, credentialSetStore?.secret(for: set))
    }

    func openSSH(profile: SessionProfile, secret: String?) {
        let logger = SessionLogger(profileName: profile.name)
        let (resolvedProfile, resolvedSecret) = resolvedSSHCredentials(for: profile, fallbackSecret: secret)
        let ssh = SSHConnectionSession(profile: resolvedProfile, secret: resolvedSecret)
        // The tab itself still carries the ORIGINAL profile — the one with
        // `credentialSetID` set and its own (possibly blank) username/auth
        // fields — so editing this session later, or looking at it in the
        // sidebar, reflects what's actually saved rather than a resolved
        // snapshot from whichever credential set happened to apply at
        // connect time.
        let opened = OpenSession(profile: profile, kind: .ssh(ssh), logger: logger)

        ssh.onClose = { [weak self, weak opened] error in
            guard let self, let opened else { return }
            Task { @MainActor in
                self.handleUnexpectedClose(opened, error: error)
            }
        }

        openSessions.append(opened)
        activeSessionID = opened.id
        connectionStates[profile.id] = .connecting

        Task { @MainActor in
            do {
                try await ssh.start()
                self.markConnected(profile)
            } catch {
                if Self.isSSH1OnlyError(error) {
                    self.fallBackToSSH1(opened, originalProfile: profile, resolvedProfile: resolvedProfile, secret: resolvedSecret)
                } else {
                    opened.connectionIssue = Self.issue(from: error)
                    self.connectionStates[profile.id] = .failed
                }
            }
        }
    }

    /// True when Citadel/swift-nio-ssh rejected the handshake specifically
    /// because the device only offers SSH-1 -- the one case where retrying
    /// with `SSH1ConnectionSession` instead of just surfacing the error is
    /// worthwhile (every other NIOSSHError is a real failure that would
    /// fail the same way again).
    private static func isSSH1OnlyError(_ error: Error) -> Bool {
        guard let sshError = error as? NIOSSHError else { return false }
        switch sshError.type {
        case .unsupportedVersion:
            // A "SSH-1.99" banner means the device speaks SSH-2 perfectly
            // well and is only advertising SSH-1 compatibility alongside
            // it. Falling back to the SSH-1 client there would quietly
            // downgrade a working modern connection to a protocol that was
            // broken by design, so those get an explanatory error instead
            // (see NIOSSHError.friendlyDescription). Only a device that
            // really offers nothing but SSH-1 routes to the fallback.
            return !String(describing: sshError).contains("SSH-1.99")
        default:
            return false
        }
    }

    /// Swaps `opened`'s tab from the SSH-2 attempt that just failed with
    /// `.unsupportedVersion` into a from-scratch SSH-1 client, transparently
    /// -- same tab, same profile, no new UI or profile field needed. Only
    /// password auth is supported on this path; a profile using key-based
    /// auth surfaces a clear error instead of silently trying a blank
    /// password.
    @MainActor
    private func fallBackToSSH1(_ opened: OpenSession, originalProfile: SessionProfile, resolvedProfile: SessionProfile, secret: String?) {
        guard resolvedProfile.authMethod == .password else {
            opened.connectionIssue = SSHConnectionIssue(
                message: "This device only speaks SSH-1, and MobaMac's SSH-1 fallback only supports password authentication (not key-based auth). Switch this profile to a password to connect.",
                isHostKeyMismatch: false,
                isDisconnection: false
            )
            connectionStates[originalProfile.id] = .failed
            return
        }

        let ssh1 = SSH1ConnectionSession(host: resolvedProfile.host, port: resolvedProfile.port, username: resolvedProfile.username, password: secret)
        opened.kind = .ssh1(ssh1)

        ssh1.onClose = { [weak self, weak opened] error in
            guard let self, let opened else { return }
            Task { @MainActor in
                self.handleUnexpectedClose(opened, error: error)
            }
        }

        Task { @MainActor in
            do {
                try await ssh1.start()
                self.markConnected(originalProfile)
            } catch {
                opened.connectionIssue = Self.issue(from: error)
                self.connectionStates[originalProfile.id] = .failed
            }
        }
    }

    func openTelnet(profile: SessionProfile) {
        let logger = SessionLogger(profileName: profile.name)
        let telnet = TelnetConnectionSession(host: profile.host, port: profile.port)
        let opened = OpenSession(profile: profile, kind: .telnet(telnet), logger: logger)

        telnet.onClose = { [weak self, weak opened] error in
            guard let self, let opened else { return }
            Task { @MainActor in
                self.handleUnexpectedClose(opened, error: error)
            }
        }

        openSessions.append(opened)
        activeSessionID = opened.id
        connectionStates[profile.id] = .connecting

        Task { @MainActor in
            do {
                try await telnet.start()
                self.markConnected(profile)
            } catch {
                opened.connectionIssue = Self.issue(from: error)
                self.connectionStates[profile.id] = .failed
            }
        }
    }

    func openSerial(profile: SessionProfile) {
        let logger = SessionLogger(profileName: profile.name)
        let serial = SerialConnectionSession(
            devicePath: profile.serialPortPath ?? "",
            baudRate: profile.baudRate ?? 9600
        )
        let opened = OpenSession(profile: profile, kind: .serial(serial), logger: logger)

        serial.onClose = { [weak self, weak opened] error in
            guard let self, let opened else { return }
            Task { @MainActor in
                self.handleUnexpectedClose(opened, error: error)
            }
        }

        openSessions.append(opened)
        activeSessionID = opened.id
        connectionStates[profile.id] = .connecting

        Task { @MainActor in
            do {
                try await serial.start()
                self.markConnected(profile)
            } catch {
                opened.connectionIssue = Self.issue(from: error)
                self.connectionStates[profile.id] = .failed
            }
        }
    }

    @MainActor
    func openLocal(profile: SessionProfile) {
        let logger = SessionLogger(profileName: profile.name)
        let opened = OpenSession(profile: profile, kind: .local, logger: logger)
        openSessions.append(opened)
        activeSessionID = opened.id
        markConnected(profile)
    }

    /// The recovery action offered when a session's `connectionIssue` is a
    /// host-key mismatch: explicitly re-trust the new key (same as deleting
    /// the stale `known_hosts` line yourself) and reconnect.
    func retryTrustingHostKey(_ session: OpenSession) {
        guard case .ssh(let ssh) = session.kind else { return }
        session.connectionIssue = nil
        connectionStates[session.profile.id] = .connecting
        Task { @MainActor in
            do {
                try await ssh.retryTrustingNewHostKey()
                self.markConnected(session.profile)
            } catch {
                session.connectionIssue = Self.issue(from: error)
                self.connectionStates[session.profile.id] = .failed
            }
        }
    }

    /// Manual reconnect (UI spec §9.2's ⌘R): cancels any auto-reconnect loop
    /// already running for this tab so the two never race each other, then
    /// makes one immediate attempt. If that attempt also fails and the
    /// profile has auto-reconnect on, hands off into the regular auto-reconnect
    /// loop rather than just giving up after the one manual try.
    func reconnect(_ session: OpenSession) {
        reconnectTasks[session.id]?.cancel()
        reconnectTasks[session.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.attemptReconnect(session)
            if session.connectionIssue != nil, session.profile.autoReconnect == true {
                self.startAutoReconnect(session)
            }
        }
    }

    /// A tab's `ConnectionSession` reported it closed — either cleanly or
    /// with an error. This fires both for genuine surprise disconnects
    /// (network drop, device reboot) and, harmlessly, as an echo of a
    /// deliberate `close(_:)` call: `close(_:)` removes the tab from
    /// `openSessions` synchronously before its own `Task { await x.close() }`
    /// finishes, so by the time that close is what triggers this callback,
    /// the guard below already sees the tab gone and does nothing.
    @MainActor
    private func handleUnexpectedClose(_ session: OpenSession, error: Error?) {
        guard openSessions.contains(where: { $0.id == session.id }) else { return }
        session.connectionIssue = Self.issue(from: error, isDisconnection: true)
        connectionStates[session.profile.id] = .failed
        if session.profile.autoReconnect == true {
            startAutoReconnect(session)
        }
    }

    /// Up to 20 attempts, 15 seconds apart (UI spec §9.2's stated caps),
    /// bailing out the moment the tab is closed, a manual reconnect takes
    /// over, or an attempt actually succeeds. Awaits `attemptReconnect`
    /// directly rather than firing it and moving on, so there's never more
    /// than one connection attempt in flight for this tab at a time.
    @MainActor
    private func startAutoReconnect(_ session: OpenSession) {
        reconnectTasks[session.id]?.cancel()
        reconnectTasks[session.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...Self.maxAutoReconnectAttempts {
                if Task.isCancelled { return }
                guard self.openSessions.contains(where: { $0.id == session.id }) else { return }
                guard session.connectionIssue != nil else { return } // already reconnected
                session.reconnectAttempt = attempt
                try? await Task.sleep(nanoseconds: Self.autoReconnectDelaySeconds * 1_000_000_000)
                if Task.isCancelled { return }
                guard self.openSessions.contains(where: { $0.id == session.id }) else { return }
                guard session.connectionIssue != nil else { return }
                await self.attemptReconnect(session)
                if session.connectionIssue == nil { return } // success
            }
            session.reconnectAttempt = 0
        }
    }

    /// Builds a brand-new `ConnectionSession` matching `session.kind`'s
    /// current case, swaps it into the same tab (so the tab identity, its
    /// scrollback-adjacent chrome, and its place in the tab bar are all
    /// undisturbed), and gives it a fresh timestamped log file rather than
    /// appending to the previous attempt's log.
    @MainActor
    private func attemptReconnect(_ session: OpenSession) async {
        // "Try Again" on a tab that never connected goes through here too.
        // Keep that labelled as a failed connection rather than flipping it
        // to "Disconnected", which would claim it had been up at some point.
        let wasDisconnection = session.connectionIssue?.isDisconnection ?? true
        session.connectionIssue = nil
        connectionStates[session.profile.id] = .connecting

        let profile = session.profile
        let newLogger = SessionLogger(profileName: profile.name)

        do {
            switch session.kind {
            case .ssh:
                let fallbackSecret = profileStore?.secret(for: profile)
                let (resolvedProfile, resolvedSecret) = resolvedSSHCredentials(for: profile, fallbackSecret: fallbackSecret)
                let ssh = SSHConnectionSession(profile: resolvedProfile, secret: resolvedSecret)
                ssh.onClose = { [weak self, weak session] error in
                    guard let self, let session else { return }
                    Task { @MainActor in
                        self.handleUnexpectedClose(session, error: error)
                    }
                }
                session.kind = .ssh(ssh)
                session.logger = newLogger
                try await ssh.start()
            case .ssh1:
                let fallbackSecret = profileStore?.secret(for: profile)
                let (resolvedProfile, resolvedSecret) = resolvedSSHCredentials(for: profile, fallbackSecret: fallbackSecret)
                let ssh1 = SSH1ConnectionSession(host: resolvedProfile.host, port: resolvedProfile.port, username: resolvedProfile.username, password: resolvedSecret)
                ssh1.onClose = { [weak self, weak session] error in
                    guard let self, let session else { return }
                    Task { @MainActor in
                        self.handleUnexpectedClose(session, error: error)
                    }
                }
                session.kind = .ssh1(ssh1)
                session.logger = newLogger
                try await ssh1.start()
            case .telnet:
                let telnet = TelnetConnectionSession(host: profile.host, port: profile.port)
                telnet.onClose = { [weak self, weak session] error in
                    guard let self, let session else { return }
                    Task { @MainActor in
                        self.handleUnexpectedClose(session, error: error)
                    }
                }
                session.kind = .telnet(telnet)
                session.logger = newLogger
                try await telnet.start()
            case .serial:
                let serial = SerialConnectionSession(
                    devicePath: profile.serialPortPath ?? "",
                    baudRate: profile.baudRate ?? 9600
                )
                serial.onClose = { [weak self, weak session] error in
                    guard let self, let session else { return }
                    Task { @MainActor in
                        self.handleUnexpectedClose(session, error: error)
                    }
                }
                session.kind = .serial(serial)
                session.logger = newLogger
                try await serial.start()
            case .local:
                return // nothing to reconnect — Local Terminal has no ConnectionSession
            }
            session.reconnectAttempt = 0
            markConnected(profile)
        } catch {
            session.connectionIssue = Self.issue(from: error, isDisconnection: wasDisconnection)
            connectionStates[profile.id] = .failed
        }
    }

    func close(_ session: OpenSession) {
        reconnectTasks[session.id]?.cancel()
        reconnectTasks[session.id] = nil
        switch session.kind {
        case .ssh(let ssh):
            Task { await ssh.close() }
        case .ssh1(let ssh1):
            Task { await ssh1.close() }
        case .telnet(let telnet):
            Task { await telnet.close() }
        case .serial(let serial):
            Task { await serial.close() }
        case .local:
            break
        }
        session.logger.close()
        openSessions.removeAll { $0.id == session.id }
        broadcastTargetIDs.remove(session.id)
        if activeSessionID == session.id {
            activeSessionID = openSessions.last?.id
        }
        // Decision (UI spec §2): status resets to idle on tab close rather
        // than persisting a stale `.failed`/`.connected` dot for a tab that
        // isn't open anymore — a red dot from an old attempt is more
        // confusing than useful once the tab is gone.
        connectionStates[session.profile.id] = .idle
    }

    /// Marks a profile connected and stamps `lastConnectedAt` on the saved
    /// profile (UI spec §1's "Recent" section reads that field). Harmless to
    /// call for a profile that was never saved (e.g. Quick Connect) — `upsert`
    /// just adds it.
    @MainActor
    private func markConnected(_ profile: SessionProfile) {
        connectionStates[profile.id] = .connected
        guard let profileStore else { return }
        var updated = profile
        updated.lastConnectedAt = Date()
        profileStore.upsert(updated, secret: nil)
    }

    /// Plain-language text for the NIO channel errors that actually reach
    /// a user here. `ChannelError` doesn't conform to `LocalizedError`, so
    /// without this it bridges to "(NIOCore.ChannelError error 0.)" -- and
    /// error 0 is `connectTimeout`, the most common one of the set, which
    /// is exactly the case someone needs a real explanation for.
    private static func describe(_ error: ChannelError) -> String {
        switch error {
        case .connectTimeout:
            return "The device accepted the TCP connection but never finished the SSH handshake in time. The port is open and something is listening, so this is usually the SSH service itself refusing to proceed: an ACL that allows the TCP connection but drops SSH, or a device that's out of available SSH sessions. Try \"ssh -vvv <user>@<host>\" from Terminal to see how far it gets."
        case .eof, .inputClosed, .outputClosed, .alreadyClosed, .ioOnClosedChannel:
            return "The device closed the connection. If that happened immediately after connecting, it usually means the device hit its session limit or rejected this source address."
        case .connectPending:
            return "A connection attempt to this device is already in progress."
        case .operationUnsupported, .inappropriateOperationForState:
            return "The connection was used in a way it doesn't support. That's a bug in MobaMac rather than a problem with the device."
        default:
            return "Network error: \(error)."
        }
    }

    private static func issue(from error: Error?, isDisconnection: Bool = false) -> SSHConnectionIssue {
        guard let error else {
            return SSHConnectionIssue(
                message: "The connection closed.",
                isHostKeyMismatch: false,
                isDisconnection: isDisconnection
            )
        }
        let message: String
        if let localizedMessage = (error as? LocalizedError)?.errorDescription {
            message = localizedMessage
        } else if let sshError = error as? NIOSSHError {
            message = sshError.friendlyDescription
        } else if String(describing: error).contains("ClientHandshakeHandler") {
            // Citadel's ClientHandshakeHandler fails its handshake promise
            // with a bare, private `Disconnected` marker error (see its
            // `deinit`) whenever the channel tears down before the SSH
            // handshake completes AND no other error was already caught --
            // i.e. a silent close. It's a local type inside Citadel itself,
            // so it can't be pattern-matched by type the way NIOSSHError
            // is above; detecting it by its printed description is the
            // only option, but it beats showing the raw
            // "(unknown context at $...)" memory-address text this prints
            // as by default.
            message = "The connection closed before the SSH handshake even started, and no specific SSH error was reported. This usually means something outside the app is responsible: a firewall/NAT dropped the connection, or the device only allows SSH from specific source IPs. Try \"ssh -vvv <user>@<host>\" from Terminal on this Mac. If that fails the same way, it confirms this isn't an app issue."
        } else if let channelError = error as? ChannelError {
            message = Self.describe(channelError)
        } else {
            // NSError bridging turns a plain Swift error into "The operation
            // couldn't be completed. (SomeModule.SomeError error 3.)" -- that
            // number is the enum case index, which means nothing to whoever
            // is reading it and nothing in a bug report either. When that's
            // the shape we'd be showing, use Swift's own description
            // instead: it at least names the actual case.
            let bridged = error.localizedDescription
            let isUselessBridgedText = bridged.contains("operation couldn't be completed")
                || bridged.contains("operation couldn\u{2019}t be completed")
            message = isUselessBridgedText ? "Connection failed: \(String(describing: error))" : bridged
        }
        let isMismatch: Bool
        if case SSHConnectionSession.SessionError.hostKeyMismatch = error {
            isMismatch = true
        } else {
            isMismatch = false
        }
        return SSHConnectionIssue(message: message, isHostKeyMismatch: isMismatch, isDisconnection: isDisconnection)
    }
}
