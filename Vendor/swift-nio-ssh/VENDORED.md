# Vendored swift-nio-ssh

Origin: https://github.com/Wellz26/swift-nio-ssh, tag 0.3.6, commit
a05e6bbe6b141ee68da3030e00275504c0595d4d. That is the fork Citadel 0.12.1
depends on, at the exact version MobaMac had resolved. Apache 2.0, see
LICENSE.txt.

MobaMac's root Package.swift declares this directory as a local path
dependency. It has the same package identity as the remote fork
("swift-nio-ssh"), so SwiftPM uses this copy everywhere in the graph,
including inside Citadel.

## What changed

Only `Sources/NIOSSH/Connection State Machine/Operations/AcceptsVersionMessages.swift`,
in `validateVersion`: a server version string whose protocol version is
"1.99" is now accepted the same way "2.0" is. Upstream rejected it with
`NIOSSHError.unsupportedVersion`.

RFC 4253 section 5.1 says a server that speaks SSH-2 but still accepts SSH-1
clients announces "1.99", and that SSH-2 clients must treat that as "2.0".
Cisco IOS and PAN-OS do this by default unless configured with
`ip ssh version 2` or the equivalent, so without this patch MobaMac could not
reach them at all.

The manifest was also cut down to just the NIOSSH library target (the
example client/server executables, performance tester, tests and the DocC
plugin dependency are dropped). The NIOSSH target's sources and settings are
otherwise unchanged.

## Why not rewrite the banner instead

Because it can't work. The server's version string is part of the key
exchange hash (V_S in RFC 4253 section 8), which the server signs with its
host key. Rewriting "SSH-1.99-..." to "SSH-2.0-..." anywhere between the
server and NIOSSH makes the client hash a different V_S than the server did,
so the host key signature check fails. The check has to accept the banner
as it is. (MobaMac 1.4 to 1.6 tried the rewrite approach; see CHANGELOG.md.)

## Updating

If Citadel moves to a newer swift-nio-ssh, re-copy `Sources/NIOSSH` from the
new version and re-apply the `validateVersion` change above, or drop this
directory once upstream accepts "1.99".
