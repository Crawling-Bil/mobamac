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

## MobaMac additions (1.20)

Network devices that turned SHA-1 off, and devices too old to have anything
else, both failed with "no algorithm in common". The parts that have to live
inside NIOSSH are here; the rest is in MobaMac's
`Sources/MobaMac/Connection/ExtraSSHAlgorithms.swift`.

- `Keys And Signatures/RSASHA2.swift` (new): RSA host keys verified with
  `rsa-sha2-256` and `rsa-sha2-512` signatures (RFC 8332), using the
  Security framework. The key is still the "ssh-rsa" key Citadel registers;
  only the signature hash differs.
- `Key Exchange/SSHKeyExchangeStateMachine.swift`: the client offers
  `rsa-sha2-512` and `rsa-sha2-256` right after `ssh-rsa` whenever an
  "ssh-rsa" key type is registered; the host key check accepts an "ssh-rsa"
  key for either name; MAC names offered are de-duplicated; MAC
  negotiation is skipped when the agreed cipher is AEAD (AES-GCM), as
  OpenSSH does, so devices offering only ETM MACs still connect; and a
  failed negotiation now carries what the peer offered (see below).
- `Keys And Signatures/NIOSSHSignature.swift`: reads the two signature
  types. `Keys And Signatures/NIOSSHPublicKey.swift`: routes them to
  `RSASHA2.verify` in both `isValidSignature` overloads.
- `NIOSSHError.swift`: `diagnosticDetail` exposes the detail string, and
  `keyExchangeNegotiationFailed(detail:)` builds a negotiation failure with
  lines `missing=`, `kex=`, `hostkey=`, `cipher=`, `mac=` listing what was
  missing and the peer's lists. MobaMac shows these in its error screen.

Each change is marked with a "MobaMac" comment in the source.

## Why not rewrite the banner instead

Because it can't work. The server's version string is part of the key
exchange hash (V_S in RFC 4253 section 8), which the server signs with its
host key. Rewriting "SSH-1.99-..." to "SSH-2.0-..." anywhere between the
server and NIOSSH makes the client hash a different V_S than the server did,
so the host key signature check fails. The check has to accept the banner
as it is. (MobaMac 1.4 to 1.6 tried the rewrite approach; see CHANGELOG.md.)

## Updating

If Citadel moves to a newer swift-nio-ssh, re-copy `Sources/NIOSSH` from the
new version and re-apply the `validateVersion` change and the 1.20
additions above, or drop this directory once upstream covers them.
