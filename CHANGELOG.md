# Changelog

Newest first. Version numbers match `CFBundleShortVersionString` in
`package-mobamac-app.sh`, and each release is tagged `v<version>.0`.

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
