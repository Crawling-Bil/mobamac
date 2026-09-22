# Changelog

Newest first. Version numbers match `CFBundleShortVersionString` in
`package-mobamac-app.sh`, and each release is tagged `v<version>.0`.

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
