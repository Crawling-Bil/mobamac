import NIO

/// Works around a real limitation in swift-nio-ssh: RFC 4253 §5 says a
/// server that sends the version string "SSH-1.99-..." supports SSH-2 and
/// only kept "1.99" instead of "2.0" for backward compatibility with SSH-1
/// clients, so a conforming client must treat "1.99" exactly like "2.0".
/// swift-nio-ssh doesn't implement that carve-out: its version check
/// (`AcceptsVersionMessages.validateVersion`) compares bytes 4..<7 against
/// "2.0" literally and throws `NIOSSHError.unsupportedVersion` for anything
/// else. Cisco IOS and PAN-OS both advertise "SSH-1.99-..." by default
/// unless hardened to `ip ssh version 2`, so plenty of fully SSH-2-capable
/// gear gets rejected before the real handshake ever starts.
///
/// This handler sits on the raw socket in front of `NIOSSHHandler` and
/// rewrites that one line ("SSH-1.99-" becomes "SSH-2.0-") before
/// NIOSSHHandler parses it. Everything after the banner is forwarded byte
/// for byte.
///
/// Two ordering hazards this has to respect, both learned the hard way:
///
/// 1. The socket is connected (and therefore already readable) before
///    Citadel installs `NIOSSHHandler`, so the server's banner can arrive
///    while this handler is still the only one in the pipeline. Anything
///    forwarded then goes nowhere and the handshake stalls until Citadel's
///    10s login timeout fires (surfacing as `ChannelError.connectTimeout`).
///    So inbound bytes are held here until downstream is known to exist.
/// 2. The signal for "downstream exists" is the first outbound flush:
///    `NIOSSHHandler.handlerAdded` writes its own version string and
///    flushes immediately when it joins an already-active channel, and that
///    flush travels out through this handler. No polling, no timers.
///
/// A genuinely SSH-1-only banner ("SSH-1.5-...", no "1.99") is passed
/// through untouched and still fails with `unsupportedVersion`, which is
/// what lets `SessionManager` fall back to `SSH1ConnectionSession`.
final class SSH199CompatibilityHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private static let legacyPrefix = "SSH-1.99-"
    private static let rewrittenPrefix = "SSH-2.0-"
    /// RFC 4253 caps a banner at 255 bytes. Well past that without a
    /// newline means this isn't a version line at all, so stop holding on
    /// to it and let NIOSSHHandler report whatever it actually is.
    private static let maxBannerBytes = 1024

    private var buffer = ByteBuffer()
    private var downstreamReady = false
    private var bannerHandled = false

    func flush(context: ChannelHandlerContext) {
        context.flush()
        guard !downstreamReady else { return }
        downstreamReady = true

        // The channel is connected with autoRead off (see
        // SSHConnectionSession.connect) so that nothing is read off the
        // socket while Citadel is still adding its handlers. Now that
        // NIOSSHHandler is demonstrably in the pipeline, reading can start:
        // the bytes the server already sent are waiting in the kernel
        // buffer, not lost.
        context.channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in }
        context.read()

        // With autoRead off there is normally nothing buffered here yet
        // (no read has happened), so this is a no-op in the common case.
        // It matters only if a read somehow landed before NIOSSHHandler
        // arrived, in which case those bytes still have to go somewhere.
        deliver(context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if downstreamReady, bannerHandled {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        deliver(context: context)
    }

    private func deliver(context: ChannelHandlerContext) {
        guard downstreamReady else { return }

        if !bannerHandled {
            guard let newlineIndex = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
                if buffer.readableBytes > Self.maxBannerBytes {
                    bannerHandled = true
                    forwardRemainder(context: context)
                }
                return
            }

            let lineLength = newlineIndex + 1 - buffer.readerIndex
            guard var line = buffer.readSlice(length: lineLength) else { return }

            if let text = line.getString(at: line.readerIndex, length: line.readableBytes),
               text.hasPrefix(Self.legacyPrefix) {
                let rewritten = Self.rewrittenPrefix + text.dropFirst(Self.legacyPrefix.count)
                var replacement = context.channel.allocator.buffer(capacity: rewritten.utf8.count)
                replacement.writeString(rewritten)
                line = replacement
            }

            bannerHandled = true
            context.fireChannelRead(wrapInboundOut(line))
        }

        forwardRemainder(context: context)
    }

    /// Forwards whatever followed the banner in the same read, if anything.
    private func forwardRemainder(context: ChannelHandlerContext) {
        guard buffer.readableBytes > 0 else { return }
        let remainder = buffer
        buffer = ByteBuffer()
        context.fireChannelRead(wrapInboundOut(remainder))
    }
}
