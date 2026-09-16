import NIO

/// Works around a real limitation in swift-nio-ssh: RFC 4253 §5 says a
/// server that sends the version string "SSH-1.99-..." supports SSH-2 and
/// only kept "1.99" instead of "2.0" for backward compatibility with SSH-1
/// clients -- a conforming client MUST treat "1.99" exactly like "2.0".
/// swift-nio-ssh doesn't implement that carve-out: its version check
/// (`AcceptsVersionMessages.validateVersion`) does a literal
/// `bytes[4..<7] == "2.0"` comparison and throws `NIOSSHError
/// .unsupportedVersion` for anything else -- confirmed by reading its
/// source directly (Sources/NIOSSH/Connection State
/// Machine/Operations/AcceptsVersionMessages.swift).
///
/// In practice this rejects perfectly modern, fully SSH-2-capable gear:
/// Cisco IOS and PAN-OS both default to advertising "SSH-1.99-..." (dual
/// v1/v2 backward-compat mode) unless an admin has explicitly hardened the
/// device to `ip ssh version 2`. That's almost certainly what's behind
/// devices that report modern algorithms (`aes256-gcm`, `ecdsa-sha2-*`,
/// etc. -- see `show ip ssh`) yet still hit `unsupportedVersion` in this
/// app: they're not SSH-1-only, swift-nio-ssh is just being stricter than
/// the RFC requires.
///
/// This handler sits directly on the raw socket, in front of
/// `NIOSSHHandler`, and looks only at the server's very first line (the
/// version banner). If it starts with "SSH-1.99-", it's rewritten in place
/// to "SSH-2.0-" before `NIOSSHHandler` ever sees it. Either way, once that
/// one line has been handled, this handler removes itself from the
/// pipeline -- every byte after that (the real, binary, eventually-
/// encrypted SSH-2 conversation) passes through completely untouched. A
/// genuinely SSH-1-only device (a banner like "SSH-1.5-..." with no "1.99")
/// is left alone here and still fails with `unsupportedVersion` exactly as
/// before, which is what lets `SessionManager` fall back to
/// `SSH1ConnectionSession` for those.
final class SSH199CompatibilityHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private static let legacyPrefix = "SSH-1.99-"
    private static let rewrittenPrefix = "SSH-2.0-"
    /// Real banners are well under this (RFC 4253 caps them at 255 bytes);
    /// bail out rather than buffering forever if a peer never sends "\n".
    private static let maxBannerBytes = 1024

    private var buffer = ByteBuffer()
    private var finishedWithBanner = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finishedWithBanner else {
            context.fireChannelRead(data)
            return
        }

        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)

        guard let newlineIndex = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
            if buffer.readableBytes > Self.maxBannerBytes {
                // Something other than a normal SSH version line -- stop
                // touching the stream and let NIOSSHHandler deal with (and
                // report on) whatever this actually is.
                context.pipeline.removeHandler(context: context, promise: nil)
                finishAndForwardRemainder(context: context)
            }
            return
        }

        let lineLength = newlineIndex + 1 - buffer.readerIndex
        guard var line = buffer.readSlice(length: lineLength) else { return }

        if let lineText = line.getString(at: line.readerIndex, length: line.readableBytes),
           lineText.hasPrefix(Self.legacyPrefix) {
            let rewritten = Self.rewrittenPrefix + lineText.dropFirst(Self.legacyPrefix.count)
            var newLine = context.channel.allocator.buffer(capacity: rewritten.utf8.count)
            newLine.writeString(rewritten)
            line = newLine
        }

        finishedWithBanner = true
        context.pipeline.removeHandler(context: context, promise: nil)
        context.fireChannelRead(wrapInboundOut(line))
        finishAndForwardRemainder(context: context)
    }

    /// Forwards whatever's left in `buffer` (bytes from the same read that
    /// arrived after the version line, if any) and marks this handler done.
    private func finishAndForwardRemainder(context: ChannelHandlerContext) {
        finishedWithBanner = true
        if buffer.readableBytes > 0 {
            let remainder = buffer
            buffer = ByteBuffer()
            context.fireChannelRead(wrapInboundOut(remainder))
        }
    }
}
