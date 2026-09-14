# MobaMac — MVP scaffold

A native macOS SSH client (MobaXterm-style), built with SwiftUI + SwiftTerm
(terminal rendering) + Citadel (SSH transport). Pure Swift Package Manager
project — no .xcodeproj needed.

Core flows covered end to end:
1. Save a session profile (SSH or local shell) — password/host go in a JSON
   file, secrets go in the macOS Keychain.
2. Open it from the sidebar into a new tab.
3. Type in the terminal, see real output — for SSH via Citadel's PTY, for
   local via SwiftTerm's own LocalProcessTerminalView.
4. Every session automatically logs to `~/Library/Logs/MobaMac/<name>_<timestamp>.log`,
   independent of on-screen scrollback — this is what fixes the original
   "output disappears when I scroll" problem, byte for byte.

## Running it

1. Open `Package.swift` in Xcode (File > Open, pick the file, not a folder) —
   or `cd MobaMac && swift run` from Terminal.
2. First open resolves SwiftTerm + Citadel from GitHub — needs network access.
3. Pick "My Mac" as the run destination, hit Run.
4. If Xcode complains about App Sandbox blocking outgoing network connections:
   Signing & Capabilities > either turn off App Sandbox (simplest for a
   personal tool) or add the "Outgoing Connections (Client)" capability.

## What's new since the first pass

- **Multi-exec / broadcast** — toolbar toggle sends whatever you type in any
  SSH tab to every open SSH tab at once (`SessionManager.broadcastEnabled`).
  A red banner stays on screen the whole time it's active, on purpose —
  this is the feature most likely to make you paste a command onto the
  wrong device if you forget it's on.
- **Close Tab** — ⌘W / toolbar button closes the active session properly
  (kills the SSH connection or local process, closes the log file).
- **`KnownHostsStore`** (`Persistence/KnownHostsStore.swift`) — a real,
  working TOFU fingerprint store (SHA-256, JSON-backed, same idea as
  `~/.ssh/known_hosts`). **Not wired into `SSHConnectionSession` yet** — see
  below.

## What's new since the second pass

- **SFTP browser** (`Connection/SFTPBrowserSession.swift`, `Views/SFTPBrowserView.swift`)
  — opens a second SFTP channel on the active SSH session, browse/download
  files. The `SFTPClient` calls themselves (`openSFTP`, `listDirectory`,
  `withFile`, `close`) are confirmed against Citadel's own README examples.
  The one soft spot: the exact property names on each directory-listing
  entry (`SFTPBrowserSession.mapEntry`) weren't verified against a compiled
  build — flagged inline with what to check if Xcode complains there.
- **Network diagnostic tools** (`Tools/NetworkTools.swift`,
  `Views/NetworkToolsView.swift`) — Ping, Traceroute, DNS lookup, TCP port
  scanner, subnet calculator, all in one panel. Ping/traceroute/DNS shell
  out to the system binaries (`/sbin/ping`, `/usr/sbin/traceroute`,
  `/usr/bin/dig`) rather than reimplementing ICMP/DNS — this needs the app
  to run **without App Sandbox** (same tradeoff already noted for Serial/
  Telnet below). Port scanning and the subnet calculator are pure Swift
  (Network.framework connect-scan, plain IPv4 bit math) with no such
  dependency.
- Both are wired into the toolbar — buttons appear next to Broadcast/Close
  Tab, SFTP only enables when the active tab is an SSH session.

## Security gap — closed

`SSHConnectionSession` now connects with `hostKeyValidator: .custom(HostKeyValidator(...))`
instead of `.acceptAnything()`. `HostKeyValidator` (nested in
`SSHConnectionSession`) implements Citadel's real
`NIOSSHClientServerAuthenticationDelegate` protocol — confirmed against the
resolved package source, not guessed — and calls
`KnownHostsStore.shared.evaluate(host:port:rawKeyBytes:)`:
- `.newHost` — first connection, TOFU: trusted and remembered.
- `.matches` — safe, connection proceeds.
- `.mismatch` — rejected with `SessionError.hostKeyMismatch`; the tab shows
  an explicit warning with a "Trust New Key & Reconnect" button instead of
  silently accepting the new key or hanging with no explanation.

The orange banner is gone — this was the app's own signal that the gap was
still open, and it isn't anymore.

## Still deferred past this MVP

- **Private key auth** — fixed for the two algorithms Citadel actually
  supports loading: RSA and Ed25519, OpenSSH-format only
  (`-----BEGIN OPENSSH PRIVATE KEY-----`). Key type is detected automatically
  via Citadel's `SSHKeyDetection`, and — contrary to what earlier drafts of
  this doc assumed — the resolved Citadel version here *does* decrypt
  encrypted OpenSSH keys (AES-128/256-CTR + bcrypt KDF, same as OpenSSH
  itself), so a passphrase in the session's Key Passphrase field works.
  Old PEM-style keys (`-----BEGIN RSA PRIVATE KEY-----`) and ECDSA keys
  (P-256/384/521) are detected but not loadable yet — both fail with a
  clear, specific error message rather than a cryptic parse failure.
- **SSH agent auth** — throws "not yet implemented".
- **PTY resize on window resize** — the hook is stubbed, not wired to an
  actual NIOSSH window-change request yet.
- **Split panes** — not built yet (see the Phase 5a section above for macros/snippets, quick connect, themes, session search, and the log viewer, which now exist).
- **RDP, VNC** — not built, not planned for a while. No mature pure-Swift
  libraries exist; realistic path is bridging FreeRDP/LibVNCClient as C
  dependencies, which is its own subproject.
- **Tab UX** — SwiftUI's TabView works but doesn't give you MobaXterm-style
  closable tabs with a hover "x" out of the box; ⌘W / the toolbar button
  covers "close current tab" for now. If per-tab close buttons matter,
  swap the tab strip for an NSViewControllerRepresentable-backed NSTabView
  later.

## What's new since the third pass

- **Serial/Console support** (`Connection/SerialConnectionSession.swift`,
  `Tools/SerialPortLister.swift`) — a session type for USB-to-serial console
  cables, built on ORSSerialPort (confirmed against its real header,
  `Sources/include/ORSSerial/ORSSerialPort.h`, not guessed). This is the
  PRD's P0 use case: consoling into a switch/router that has no IP yet, or
  whose network path is down. The New Session sheet lists currently
  connected adapters (refreshable) and a baud-rate picker defaulting to
  9600 — the standard console speed for Cisco/Palo Alto/Fortinet/Aruba
  gear. Needs the app to run **without App Sandbox** (already the case —
  see the Ping/Traceroute/DNS note above) since sandboxed apps need extra
  IOKit entitlements per USB-serial chipset to open `/dev/cu.*` devices.
- **Telnet support** (`Connection/TelnetConnectionSession.swift`) — a raw
  TCP client over `Network.framework`, since Citadel has no Telnet
  equivalent. Implements just enough of RFC 854's option-negotiation
  (a blanket WONT/DONT refusal to every WILL/DO) to stay usable against
  real legacy gear without hanging on a handshake. The New Session sheet
  shows a plain-text warning — Telnet sends everything, including
  passwords, unencrypted.
- Both session types share `Views/RawTerminalHostView.swift`, a bare
  SwiftTerm bridge for any non-SSH `ConnectionSession` (no multi-exec/
  broadcast wiring — that stays SSH-only, since it doesn't map cleanly onto
  a console port or a legacy Telnet session). Connection failures for
  either surface the same in-tab error UI introduced for SSH host-key
  issues, not a silently blank tab.

## What's new since the fourth pass (Phase 5a)

- **Themes** (`Support/TerminalTheme.swift`) — five built-in color schemes
  (Default, Dracula, Solarized Dark, Solarized Light, Monokai), picked per
  session profile in the New Session sheet and applied via
  `TerminalView.installColors` / `nativeBackgroundColor` /
  `nativeForegroundColor`. `SwiftTerm.Color`'s public `red`/`green`/`blue`
  (0–65535) components are converted to `NSColor` through a small
  `NSColor(swiftTermColor:)` convenience init, since SwiftTerm's own
  `NSColor.make(color:)` helper isn't `public` and can't be called from
  outside the package. A profile saved before themes existed has no
  `themeID` in its JSON and falls back to Default — same backward-compat
  pattern as the Serial fields from the previous pass.
- **Snippets / macros** (`Models/Snippet.swift`, `Persistence/SnippetStore.swift`,
  `Views/SnippetsPanelView.swift`) — save a name + command, fire it into the
  active tab with one click. Firing goes through a new
  `OpenSession.terminalView: TerminalView?` weak reference set by whichever
  host view creates the actual SwiftTerm view, calling the same
  `TerminalView.send(txt:)` a real keystroke uses — confirmed against
  SwiftTerm's own source, not guessed — so a snippet fires identically
  whether the active tab is SSH, Telnet, Serial, or Local, with no
  session-kind-specific plumbing. `SessionManager.sendToActive(_:)` is the
  single entry point that makes that work. Persisted as plain JSON (no
  secrets involved) at `~/Library/Application Support/MobaMac/snippets.json`.
- **Quick Connect** (`Views/QuickConnectSheet.swift`) — SSH or Telnet to a
  host right now without saving a session profile. Builds an in-memory
  `SessionProfile` and hands it straight to the existing
  `SessionManager.openSSH`/`openTelnet`, so it never touches `ProfileStore`
  or the Keychain.
- **Session search** (`Views/SidebarView.swift`) — a `.searchable` filter
  over the sidebar's session list, matching on name or host.
- **In-app log viewer** (`Views/LogViewerView.swift`) — browse and read the
  per-session log files `SessionLogger` already writes to
  `~/Library/Logs/MobaMac/`, without leaving the app or hunting through
  Finder. Caps what's pulled into memory at 2 MB per file (seeks to the
  tail via `FileHandle`) so a huge log doesn't stall the UI.
- **Split panes are not in this pass** — deliberately deferred rather than
  layered on top of Serial/Telnet (previous pass) before either had a real
  `swift build` behind it. Splitting a tab into multiple panes also raises
  a design question the PRD doesn't answer on its own — does a split mirror
  one session into two views, or host two independent sessions side by
  side — worth settling before building it rather than guessing.

**Heads up on this pass specifically:** since the previous (Serial/Telnet)
pass was pushed, `swift build` hasn't been run and confirmed successful yet
— so this will be the first real build test of the `ORSSerialPort` SwiftPM
dependency resolving at all, in addition to everything in this pass. If
`swift build` fails, share `build.log` (or paste the error) rather than
guessing at a fix blind.

### Fixes after the first Phase 5a build feedback

- **Log viewer showed raw escape codes** — a themed local-shell prompt
  (Powerlevel10k and similar) leans hard on ANSI/VT100 escape sequences for
  colors, cursor movement, and redrawing its line — a real terminal
  interprets those, but the log viewer was just displaying the session
  log's raw bytes as plain text, which looked like garbled bracket/number
  soup. `LogViewerView.stripTerminalEscapes` now strips CSI/OSC escape
  sequences and other control bytes before the log is shown, and turns
  bare `\r` line-redraws into real line breaks instead of letting them
  overlap silently.
- **Log viewer can't get you to the file in Finder** — added a "Show in
  Finder" toolbar button (`NSWorkspace.shared.activateFileViewerSelectingPath`)
  next to Refresh, enabled once a log is selected, so you can copy the raw
  file out yourself.
- **Macros needed a click** — `Snippet` gained an optional `shortcutKey`
  (single letter/digit, backward-compatible the same way every other
  optional field on these models is). Set one in the snippet's edit sheet
  and it fires with ⌥⌘+that key from anywhere in the app — including while
  a terminal view has focus — via a new "Macros" menu MobaMacApp builds
  from the same `SnippetStore`. Menu key equivalents are checked by AppKit
  before a keystroke reaches the terminal's own NSView, which is what
  makes this work without an on-screen click. Two snippets sharing a key
  don't crash anything, but only one of them will actually fire — the
  snippet edit sheet flags that clash inline before you save.

## UI/UX overhaul (Customer/Device Type tree, safety-scoped broadcast, command palette)

Implements `MobaMacUISessionSpec.md` end to end. Six of its seven sections
landed; the seventh (a per-session notes field) was explicitly deferred and
is not built.

- **Sidebar restructure** — `SidebarView` now nests saved profiles under a
  `Customer -> Device Type` tree (`DisclosureGroup` inside `DisclosureGroup`),
  backed by `ProfileStore.customerGroups` / `deviceTypeGroups(under:)` /
  `findOrCreateGroup(customer:deviceType:)`. A `Recent` section above it
  lists the 3 most recently connected profiles (`lastConnectedAt`, set by
  `SessionManager.markConnected`). Profiles whose `groupID` doesn't resolve
  to a real device-type group fall into an `Ungrouped` section instead of
  disappearing.
- **Per-session status dots** — `SessionManager.ConnectionState` (`idle` /
  `connecting` / `connected` / `failed`) is tracked per profile id and drawn
  as a colored `StatusDot` next to each sidebar row (gray outline / yellow /
  green / red).
- **Safety-scoped broadcast** — the old all-or-nothing `broadcastEnabled`
  toggle is gone. `SessionManager.broadcastTargetIDs: Set<OpenSession.ID>`
  is an explicit per-session opt-in set, edited from the toolbar's new
  `BroadcastPopoverView`. Opening the popover with nothing selected
  auto-scopes it to open SSH tabs under the same top-level customer as the
  active tab (`ProfileStore.topLevelCustomerID(for:)`); anything outside
  that customer shows in orange in the popover so including it is always a
  deliberate click, never a side effect of turning broadcast on.
- **New Session form fields** — `NewSessionSheet` gained a Customer text
  field (with a `Menu` combo-box of existing customer names) and a Device
  Type picker (`DeviceTypeOption`: Firewall / Switch / Router / WLC), plus a
  protocol picker row of icon buttons at the top (SSH and Local are live;
  Serial and RDP are shown but disabled as a roadmap hint — Serial is
  actually implemented already and reachable via the Type picker further
  down, RDP doesn't exist as a `SessionKind` yet).
- **Terminal font + optional syntax highlighting** — every terminal host
  view (`SSHTerminalHostView`, `RawTerminalHostView`, `LocalTerminalHostView`)
  now calls a new `TerminalView.applyMobaMacTerminalFont()` (Courier New,
  falling back through Consolas / DejaVu Sans Mono / the system monospaced
  font). SSH sessions also get a per-session highlighting toggle
  (`OpenSession.highlightingEnabled`, flipped from a new toolbar button) that
  routes output through `LineBuffer` + `TerminalHighlighter` to colorize
  IPs, MAC addresses, up/down status, and vendor error strings. This only
  runs when the toggle is on — it requires buffering until a full line
  arrives, which delays all output (including the user's own echoed
  keystrokes) until Enter, so it stays opt-in per session rather than a
  default. The session log always tees the raw, unmodified bytes regardless
  of the toggle.
- **Command palette (⌘K)** — `CommandPaletteView`, opened via
  `SessionManager.showingCommandPalette` (bound to a new "Go" menu / ⌘K
  shortcut in `MobaMacApp`). Live-filters every saved profile by name, host,
  or Customer/Device Type breadcrumb; arrow keys move the selection, Enter
  connects, Esc closes — no confirmation step, since a command palette is
  supposed to be the fast path.

## Where to look first if something's off after `swift build`

Two spots are flagged with comments as "verify against your resolved
package version" because the exact API shape has moved across releases:

- `SSHConnectionSession.swift` — the PTY stdin writer's type/method name.
- `SSHTerminalHostView.swift` — the exact `TerminalViewDelegate` method list.

Both compile against the API confirmed from each project's README/source at
the time this was written, but pin your own dependency versions in
`Package.swift` once it builds clean, so an upstream update doesn't silently
break you.
