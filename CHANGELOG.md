# Changelog

Newest first. Version numbers match `CFBundleShortVersionString` in
`Scripts/build-app.sh`, and each release is tagged `v<version>.0`.

## 1.18

- Wording across the app is consistent: one term per concept, no
  references to other products, and plainer descriptions in tooltips and
  error messages. The Macros menu is now Snippets, matching the panel it
  has always drawn from.
- The serial console hint was wrong about Aruba. CX switches default to
  115200, not 9600.
- Sessions can send startup commands after connecting, one per line.
  This is where "terminal length 0", "set cli pager off",
  "screen-length 0 temporary" or "no page" belongs, so long output stops
  arriving one page at a time. A credential set can carry a default list
  for every session that uses it.
- The commands wait for the device to be ready rather than being sent
  the moment the connection opens, because a device is usually still
  printing its login banner then and anything sent is discarded with no
  error. A session can give a prompt pattern instead of waiting, and
  Settings has an Advanced tab for the timing on slower devices.
- Startup commands run again after every reconnect, since a device that
  just rebooted is back to its default paging. They are never sent to
  broadcast targets, and they appear in the session log like anything
  else typed.
- Cmd-F searches the active terminal's scrollback. The find bar shows
  how many matches there are and which one you are on, steps through
  them with Return and Shift-Return, and has case-sensitive and regular
  expression options. Esc closes it.
- A snippet can be shown as a button above the terminal, so a command
  run dozens of times a day is one click rather than opening a panel
  first. Tick it in the Snippets panel and drag to set the order. View
  has a Show Button Bar switch.
- A snippet can be limited to certain device types, so switch commands
  stay off the bar while a firewall tab is in front, and can be set to
  ask before running, which is worth doing for reload or write erase.
- While broadcast is on, the button bar turns red and each button says
  how many sessions a click would reach.
- The terminal area can be split, from View then Layout: side by side,
  one above the other, or four at once. Each pane has a small menu in
  its corner for choosing which open session it shows, and the dividers
  can be dragged. A session appears in one pane at a time, so picking
  one that is already on screen swaps the two panes.
- Every pane tells its device the size of that pane, so long output
  wraps and pages correctly in a narrow split instead of being laid out
  for the full window. Dragging a divider sends the new size too.
- The focused pane has an accent border, and Control-Option with the
  arrow keys moves between panes. The status bar, the SFTP, Highlight
  and Theme controls, the find bar and the button bar all follow the
  focused pane rather than the active tab, so what the window says is
  always the device you are typing into.
- Closing a tab clears whichever pane was showing it.

## 1.17

- Duplicate a session from its context menu in the sidebar, or with
  Cmd-D for the one in the active tab. It opens straight into the form
  with everything filled in, so adding twenty switches for one customer
  is twenty names and addresses rather than twenty full forms. The
  password comes across too; if it can't be read back, the copy says so
  instead of failing to log in later.
- An update will not restart MobaMac while a session is still
  connected. It says how many, and offers to install anyway or wait --
  waiting installs it the next time MobaMac is quit.
- Settings shows when updates were last checked for.
## 1.16

- MobaMac updates itself. It checks once a day, shows what changed, and
  installs the new version in place. No more downloading a zip, deleting
  the old app and dragging in the new one. MobaMac > Check for Updates
  checks right away, and the item below it turns the daily check off.
- The app is now signed with a stable self-signed certificate instead of
  a throwaway ad-hoc one. Without that, macOS treats each build as a
  different app and asks for Keychain access to every saved SSH password
  again after every update. Building from source now needs a certificate
  created once; the README has the four steps.
- Session logs are plain text. Color codes, cursor movement and the
  redrawing a prompt does are stripped, so a log reads the way the screen
  did and can go straight into a report. This covers SSH, SSH-1, Telnet,
  Serial and the local terminal alike. A progress bar or spinner is kept
  as the line it finished on, not every frame it drew.
- The status bar no longer covers the last row of the terminal. It also
  made the device believe the screen was a row taller than it was, so
  long output like "show running-config" paged against the wrong height.
- There is a Settings window (Cmd-,). It holds the appearance setting,
  the update options, and everything about logging.
- The app follows System, Light or Dark, whichever you pick. This is the
  app's own windows only: the terminal keeps its own color theme, so a
  dark terminal in a light app works the way it always did.
- Session logs can go in a folder of your choosing instead of
  ~/Library/Logs/MobaMac. New sessions use the new folder; sessions
  already open keep writing where they started. If the folder turns out
  to be unavailable, on an unplugged drive say, the session still
  connects and its log goes to the default folder, with a note in the
  status bar.
- Old logs are deleted only from the folder logging currently points at,
  and only MobaMac's own .log and .raw files, since the folder you pick
  may well have your own files in it.
- Closing a tab whose session is still connected now asks first, however
  you close it. Tabs that already dropped, failed or ended close straight
  away, and so does a local terminal, because nothing is lost there. The
  dialog has "Don't ask again", and Settings has the switch to turn it
  back on.
- Quitting, or closing the window, with sessions still connected asks
  once for all of them rather than once per tab.
- Tabs can be switched from the keyboard: Cmd-1 to Cmd-8 for a tab by
  position, Cmd-9 for the last one, Cmd-Shift-[ and Cmd-Shift-] to move
  left and right, and Ctrl-Tab and Ctrl-Shift-Tab for the same. The
  Window menu lists the open tabs with their keys. Macros keep Opt-Cmd
  and did not change.
- Two optional habits from MobaXterm and PuTTY, both off by default and
  both in Settings under Terminal: "Copy on select" and "Right-click
  pastes". With right-click paste on, Control-click still opens the
  context menu, and a multi-line paste still asks first.

## 1.15

- New status bar along the bottom of the window: protocol and
  user@host:port for the active tab, how long it has been connected,
  and the name of the log file it is writing. Click the log file name
  to show it in Finder.
- The broadcast banner is gone. Broadcast now shows as an indicator in
  the status bar, red when the tab you are looking at is one of the
  targets, so it no longer takes a full row above the terminal.
- The window title is the active session's name, with the host as a
  subtitle, instead of every window being called "MobaMac".
- The toolbar is grouped into a "Panels" menu (SFTP, Snippets, Logs,
  Network Tools) and a "Session" menu (Highlight, Theme, Close Tab),
  leaving Quick Connect and Broadcast on their own. It is also a real
  customizable toolbar now: View > Customize Toolbar rearranges it and
  macOS remembers the arrangement.
- Close Tab (Cmd-W) has moved to the File menu, so the shortcut keeps
  working whatever you do to the toolbar.
- Tabs are their own row above the terminal instead of a pill in the
  middle of the toolbar. Each tab shows a connection dot, and a close
  button on hover. Middle-click closes a tab, and tabs can be dragged
  to reorder.
- The Add menu no longer appears twice. The copy at the bottom of the
  sidebar is gone; the one in the toolbar is pinned to the leading end
  where macOS cannot push it into the overflow menu.
- Network Tools is a resizable panel on the right instead of a sheet,
  so you can ping a gateway while typing in the session behind it. The
  panel minimizes to a strip, and closing it no longer throws away
  what is in it.
- Each network tool keeps its own host and results. Switching from
  Ping to Traceroute no longer shows the stale ping output, and coming
  back to Ping shows what Ping actually printed.

## 1.14

- Typing `exit` or `logout`, or a device closing the session normally,
  now shows "Session ended" with a Reconnect button. Before it was
  treated as a dropped connection and, with auto-reconnect on, MobaMac
  logged straight back in.
- Quick Connect has a "Save password" checkbox, off by default. Without
  it, the password is only kept for the open tab.
- When MobaMac has no password for a session (not saved, or lost from
  the Keychain), the tab asks for one instead of sending an empty
  password. A rejected password asks again rather than offering a Try
  Again that resends it, and stops auto-reconnect so a wrong password
  isn't retried up to 20 times against the device.
- The SSH-1 fallback now verifies the device's host key against known
  hosts, the same trust-on-first-use check SSH-2 connections get. It
  used to accept any key. SSH-1 keys are stored separately from a
  device's SSH-2 key.
- Reconnect attempts no longer leave an empty log file behind each time
  they fail, and the previous log file is now closed instead of left
  open.
- A full disk no longer crashes the app while it writes a session log.
- The known hosts list is safe to use from several connections opening
  at the same time.

## 1.13

Fixes the 1.12 keepalive guard being too strict: after some ordinary
actions the keepalive stopped for good until the next Enter.

1.12 treated every key other than Enter, Ctrl-C and Ctrl-U as "something
typed and not submitted". Two everyday cases broke that:

- Typing something and erasing it with Backspace still counted as typed.
- Single-key answers that are never followed by Enter, like `n` at a
  `[confirm]` prompt or Space at `--More--`, counted as typed forever.

Now Backspace counts back down, and the count resets whenever the device
starts a new line, which is what happens after it accepts a single-key
answer. The screen check is unchanged and still refuses anything that
isn't a plain prompt, including a half-typed command redrawn after a log
message.

For troubleshooting, starting the app from Terminal with
`MOBAMAC_DEBUG_KEEPALIVE=1` prints why each keepalive was sent or held
back.

## 1.12

Safety fix: the idle keepalive could confirm a reload.

To stop a device's idle timeout from logging the session out, MobaMac
types a newline after 30 idle seconds. Network gear confirms destructive
commands with that same Enter. Type `reload`, get
`Proceed with reload? [confirm]`, walk away for half a minute, and the
keepalive pressed Enter for you. Same for `write erase`, `delete flash:`
and any other `[confirm]` prompt.

The keepalive now only goes out when all of these are true:

- Nothing was sent or received for the whole interval. Output counts
  now, so it can't land in the middle of a long `show tech`. Before,
  only typing reset the timer.
- Nothing is half-typed on the line. A recalled or partly typed
  `reload` would otherwise be executed.
- The last line on screen is an ordinary prompt ending in `#`, `>`,
  `$`, `%`, or a single bracketed word like Huawei's `[sysname]`. Any
  line with `[confirm]`, `[yes/no]`, `[y/n]`, `(y/n)`, `(y or n)`,
  `--More--`, a `?`, or ending in `:` (password and `[Y/N]:` prompts)
  gets no keepalive.

Checked against prompts from Cisco IOS, Huawei VRP, FortiOS, PAN-OS,
Junos and Linux shells, and against the confirmation prompts of reload,
write erase, delete, copy and save on those platforms. If a device's
prompt isn't recognised the keepalive simply doesn't fire, and the worst
case is the device timing the session out, as it would without MobaMac.

## 1.11

Tidier repository and log files. No change to how connections work.

Session logs are now named `2026-09-22_14-30-15_sw-ntt-dist01.log`:
timestamp first so a name sort is also a date sort, and the session name
reduced to plain characters. Quick Connect names such as `10.25.2.1:22`
used to put a colon in the filename, which Finder shows as a slash. A
second log opened in the same second now gets a `-2` suffix; before, it
overwrote the first one.

Repository layout: build, release and icon scripts moved to `Scripts/`
(`Scripts/build-app.sh`, `Scripts/release.sh`, `Scripts/make-icon.sh`),
the icon and logo to `Assets/`, the SSH-1 client to `Connection/SSH1/`,
and views into `Terminal/`, `Sidebar/`, `Sessions/` and `Panels/`
folders. A stray `build.log` is no longer tracked. The scripts work from
any directory. See the layout in README.md.

## 1.10

Fixes reconnecting, and connecting from the Recent list, for sessions
opened through Quick Connect. Both failed with
`allAuthenticationOptionsFailed` even though the first connection worked.

Quick Connect keeps the password in memory only. But a successful
connection saves the session so it shows up under Recent, and that save
was done without the password. Reconnect, Recent and the command palette
all look the password up in the Keychain, found nothing, and sent an
empty one.

Now:

- A tab remembers the password it was opened with, so Reconnect and Try
  Again always retry with the same credentials, whether or not they were
  ever saved.
- When a password connection succeeds and the session gets saved, the
  password that just worked is saved with it, in the Keychain like any
  other saved session's. Sessions that take their login from a credential
  set are left alone.
- A rejected login now says so in plain words.

Sessions that went into Recent from Quick Connect in 1.9 or earlier are
still missing their password. Connect to them once through Quick Connect
again, or edit the session and enter the password.

## 1.9

Cisco IOS and Palo Alto devices that advertise SSH version 1.99 can now be
reached. That covers the default configuration of both.

Two separate things were stopping them, and the second was hidden behind
the first:

1. swift-nio-ssh rejects a "1.99" version banner outright, although RFC
   4253 says an SSH-2 client must treat it as "2.0". MobaMac now builds
   against a vendored copy of the exact swift-nio-ssh version it was
   already using, with that one check fixed (Vendor/swift-nio-ssh).
2. These devices typically only have an RSA host key, and MobaMac was only
   offering the ed25519 and ECDSA host key types NIOSSH bundles, so the key
   exchange would have failed next with no algorithm in common. MobaMac now
   also offers Citadel's ssh-rsa host key support, plus aes128-ctr and
   diffie-hellman-group14. These are appended to the lists, so devices that
   already worked negotiate exactly what they did before.

Also: pressing Try Again on a tab that never connected no longer relabels
its error as "Disconnected".

## 1.8

Makes it possible to create a folder again.

The sidebar's "Add" menu (New Session, New Folder, Manage Folders) was a
toolbar item with no placement, so macOS left it competing with the
detail pane's nine-item toolbar group and pushed it into the toolbar's
overflow menu on anything but a very wide window. The only other way to
reach "New Folder" was the context menu on an existing Customer folder,
which is no help on a fresh install where the only folder is Ungrouped.

That menu is now pinned to the leading end of the toolbar next to the
sidebar toggle, and the same menu also sits at the bottom of the
sidebar, where window width can't hide it.

Also merged the sidebar's two sheets into one. Two `.sheet(isPresented:)`
modifiers stacked on the same view is a known way to have one of them
quietly never present, which would have looked like "New Folder does
nothing" as soon as the menu became reachable.

## 1.7

Fixes SSH connections, which 1.4 through 1.6 broke for every device.

1.4 tried to rewrite the "SSH-1.99" version banner that Cisco IOS and
PAN-OS advertise by default, since swift-nio-ssh rejects that banner
even though RFC 4253 says a client should treat it as SSH-2. Doing that
needed a channel handler sitting in front of NIOSSHHandler, which meant
switching to Citadel's `SSHClient.connect(on:)`. That call installs its
handlers straight from the calling thread instead of hopping to the
event loop, guarded only by an assert that release builds compile out.
The handshake never got going, and every connection died on Citadel's
10 second login timeout.

That approach is gone. Connections are back on the code path that
worked in 1.2.

Devices advertising SSH-1.99 still can't be reached, but the error now
explains what is actually happening and gives the device-side fix
(`ip ssh version 2` on Cisco IOS). They no longer fall through to the
SSH-1 client either: a 1.99 device speaks SSH-2 perfectly well, so
connecting to it over SSH-1 would be a silent downgrade.

Skip 1.4, 1.5 and 1.6. All three break SSH.

## 1.6

Broken, see 1.7.

A connection that failed to come up now offers "Try Again" (also Cmd-R)
instead of only "Close Tab", since plenty of those failures are
transient. The auto-reconnect counter reads its limit from the constant
that enforces it, so the number shown can't drift from the number used.
Em dashes removed from every user-facing string.

## 1.5

Broken, see 1.7. An incomplete fix for the 1.4 regression.

## 1.4

Broken, see 1.7.

## 1.3

Adds a from-scratch SSH-1 client, used automatically when a device
offers nothing but SSH-1. Password authentication only, DES and 3DES
only. No build was released for this version.

## 1.2

Fixes a crash (SIGABRT) when a connection changed state. Connection
state was published from a background thread, which reached AppKit's
menu code off the main thread and aborted the process.

## 1.1

SSH failures show a real explanation instead of "NIOSSH.NIOSSHError
error 1". Handshake-level failures against network gear each get their
own message: weak key exchange, no shared algorithm, unsupported
version, rejected host key, and a connection dropped mid-handshake.

## 1.0

First build. SSH, Telnet, Serial and local terminal tabs, a sidebar
grouped by customer and device type, Keychain-backed credentials,
session logging, themes, macros, quick connect, broadcast to several
sessions at once, and an SFTP browser.
