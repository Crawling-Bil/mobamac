import Foundation
import Network
import CryptoKit
import Security

/// A from-scratch SSH-1 client, used only as an automatic fallback when a
/// device's SSH server is old enough that `SSHConnectionSession` (Citadel,
/// SSH-2 only) fails with `NIOSSHError.unsupportedVersion`. SSH-1 was
/// deprecated industry-wide decades ago -- swift-nio-ssh and every other
/// modern SSH library intentionally refuses to speak it -- but some real
/// network gear MobaMac's users hit (old Cisco/PA units, terminal servers)
/// genuinely has no SSH-2 option, so this exists purely to still let those
/// devices be reached, not as an endorsement of the protocol.
///
/// Scope, deliberately narrow:
///  - Password authentication only. No RSA/rhosts SSH-1 auth -- if a
///    profile is set to key-based auth, `SessionManager` shouldn't route it
///    here at all (see the fallback wiring in SessionManager.swift).
///  - Ciphers: DES and SSH-1's own "3des" (three chained single-DES-CBC
///    passes -- see `SSH1Cipher`), the two most commonly offered by legacy
///    gear. Blowfish/RC4/IDEA aren't implemented; a device offering only
///    those fails cleanly with `SSH1Error.noSupportedCipher`.
///  - No SSH-1 agent forwarding, X11 forwarding, or port forwarding --
///    just an interactive shell, which is all a terminal tab needs.
///
/// IMPORTANT: this was written without a Swift toolchain or a live SSH-1
/// server to test against (see the PR/commit message for context) --
/// carefully cross-checked against the historical SSH-1 protocol
/// description, but real-device testing is what will actually prove it out
/// and shake out any remaining wire-format mistakes.
final class SSH1ConnectionSession: ConnectionSession {
    var onOutput: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let host: String
    private let port: UInt16
    private let username: String
    private let password: String?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "MobaMac.SSH1")
    private var inputBuffer: [UInt8] = []

    private var outgoingCipher: SSH1Cipher?
    private var incomingCipher: SSH1Cipher?
    private var readLoopTask: Task<Void, Never>?

    init(host: String, port: Int, username: String, password: String?) {
        self.host = host
        self.port = UInt16(clamping: max(0, port))
        self.username = username
        self.password = password
    }

    enum SSH1Error: LocalizedError {
        case connectionCancelled
        case connectionClosed
        case protocolError(String)
        case noSupportedCipher
        case authenticationFailed
        case missingCredentials

        var errorDescription: String? {
            switch self {
            case .connectionCancelled:
                return "The SSH-1 connection was closed before it finished connecting."
            case .connectionClosed:
                return "The SSH-1 connection closed unexpectedly."
            case .protocolError(let message):
                return "SSH-1 protocol error: \(message)"
            case .noSupportedCipher:
                return "This device only offers SSH-1 ciphers MobaMac doesn't implement (only DES and 3DES are supported)."
            case .authenticationFailed:
                return "The device rejected the SSH-1 username/password."
            case .missingCredentials:
                return "No password is available for this SSH-1 connection -- SSH-1 fallback only supports password authentication."
            }
        }
    }

    private enum SSH1MessageType: UInt8 {
        case disconnect = 1
        case publicKey = 2
        case sessionKey = 3
        case user = 4
        case authPassword = 9
        case requestPTY = 10
        case windowSize = 11
        case execShell = 12
        case success = 14
        case failure = 15
        case stdinData = 16
        case stdoutData = 17
        case stderrData = 18
        case exitStatus = 20
        case exitConfirmation = 21
    }

    // MARK: - ConnectionSession

    func start() async throws {
        guard let password else { throw SSH1Error.missingCredentials }

        try await openSocket()

        let serverBanner = try await readVersionBanner()
        guard serverBanner.hasPrefix("SSH-1") else {
            throw SSH1Error.protocolError("Server banner \"\(serverBanner)\" isn't an SSH-1 banner.")
        }
        try await sendVersionBanner()

        let (publicKeyMsgType, publicKeyPayload) = try await readPacket()
        guard publicKeyMsgType == SSH1MessageType.publicKey.rawValue else {
            throw SSH1Error.protocolError("Expected SSH_SMSG_PUBLIC_KEY (2), got message type \(publicKeyMsgType).")
        }
        let info = try Self.parsePublicKeyPacket(publicKeyPayload)

        let sessionID = Self.computeSessionID(
            hostModulus: info.hostKey.modulus,
            serverModulus: info.serverKey.modulus,
            cookie: info.cookie
        )

        let realSessionKey = Self.randomBytes(32)
        var wireSessionKey = realSessionKey
        for i in 0..<16 {
            wireSessionKey[i] ^= sessionID[i]
        }

        let cipherType: SSH1CipherType
        if info.supportedCiphersMask & (1 << 3) != 0 {
            cipherType = .des3
        } else if info.supportedCiphersMask & (1 << 2) != 0 {
            cipherType = .des
        } else {
            throw SSH1Error.noSupportedCipher
        }

        let encryptedKey = try Self.doubleRSAEncrypt(wireSessionKey, serverKey: info.serverKey, hostKey: info.hostKey)

        var sessionKeyPacket: [UInt8] = [cipherType.rawValue]
        sessionKeyPacket.append(contentsOf: info.cookie)
        sessionKeyPacket.append(contentsOf: Self.encodeMPInt(encryptedKey))
        sessionKeyPacket.append(contentsOf: Self.encodeUInt32(0)) // protocol_flags
        try await writePacket(type: SSH1MessageType.sessionKey.rawValue, data: sessionKeyPacket)

        // Every packet from here on, in both directions, is encrypted
        // continuously with the real (un-XORed) session key -- see
        // SSH1Cipher's doc comment for why two independent instances.
        outgoingCipher = SSH1Cipher(type: cipherType, sessionKey: realSessionKey)
        incomingCipher = SSH1Cipher(type: cipherType, sessionKey: realSessionKey)

        try await writePacket(type: SSH1MessageType.user.rawValue, data: Self.encodeString(Array(username.utf8)))
        let (userReplyType, _) = try await readPacket()
        if userReplyType == SSH1MessageType.success.rawValue {
            // No further authentication required -- unusual, but valid.
        } else if userReplyType == SSH1MessageType.failure.rawValue {
            try await writePacket(type: SSH1MessageType.authPassword.rawValue, data: Self.encodeString(Array(password.utf8)))
            let (passwordReplyType, _) = try await readPacket()
            guard passwordReplyType == SSH1MessageType.success.rawValue else {
                throw SSH1Error.authenticationFailed
            }
        } else {
            throw SSH1Error.protocolError("Unexpected reply to SSH_CMSG_USER: message type \(userReplyType).")
        }

        var ptyPayload = Self.encodeString(Array("xterm-256color".utf8))
        ptyPayload.append(contentsOf: Self.encodeUInt32(24)) // rows
        ptyPayload.append(contentsOf: Self.encodeUInt32(80)) // cols
        ptyPayload.append(contentsOf: Self.encodeUInt32(0))  // pixel width
        ptyPayload.append(contentsOf: Self.encodeUInt32(0))  // pixel height
        ptyPayload.append(0) // TTY_OP_END -- no explicit terminal modes requested
        try await writePacket(type: SSH1MessageType.requestPTY.rawValue, data: ptyPayload)
        let (ptyReplyType, _) = try await readPacket()
        if ptyReplyType != SSH1MessageType.success.rawValue && ptyReplyType != SSH1MessageType.failure.rawValue {
            throw SSH1Error.protocolError("Unexpected reply to SSH_CMSG_REQUEST_PTY: message type \(ptyReplyType).")
        }
        // A FAILURE reply here isn't treated as fatal -- some old servers
        // reject PTY parameters they don't like but still grant a shell.

        try await writePacket(type: SSH1MessageType.execShell.rawValue, data: [])

        readLoopTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    func send(_ data: Data) async {
        try? await writePacket(type: SSH1MessageType.stdinData.rawValue, data: Self.encodeString([UInt8](data)))
    }

    func resize(cols: Int, rows: Int) async {
        var payload = Self.encodeUInt32(UInt32(max(0, rows)))
        payload.append(contentsOf: Self.encodeUInt32(UInt32(max(0, cols))))
        payload.append(contentsOf: Self.encodeUInt32(0))
        payload.append(contentsOf: Self.encodeUInt32(0))
        try? await writePacket(type: SSH1MessageType.windowSize.rawValue, data: payload)
    }

    func close() async {
        readLoopTask?.cancel()
        connection?.cancel()
    }

    // MARK: - Post-handshake read loop

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                let (type, payload) = try await readPacket()
                switch type {
                case SSH1MessageType.stdoutData.rawValue, SSH1MessageType.stderrData.rawValue:
                    let (bytes, _) = Self.decodeString(payload, at: 0)
                    onOutput?(Data(bytes))
                case SSH1MessageType.exitStatus.rawValue:
                    try? await writePacket(type: SSH1MessageType.exitConfirmation.rawValue, data: [])
                    onClose?(nil)
                    return
                case SSH1MessageType.disconnect.rawValue:
                    let (reasonBytes, _) = Self.decodeString(payload, at: 0)
                    let reason = String(bytes: reasonBytes, encoding: .utf8) ?? "The device disconnected."
                    onClose?(SSH1Error.protocolError(reason))
                    return
                default:
                    // Stray SUCCESS/FAILURE acks for optional requests
                    // (e.g. window-size) or anything else unhandled --
                    // ignore rather than tearing the session down over it.
                    break
                }
            } catch {
                onClose?(error)
                return
            }
        }
    }

    // MARK: - Raw socket plumbing (mirrors TelnetConnectionSession's pattern)

    private func openSocket() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 22,
                using: .tcp
            )
            self.connection = conn

            var didResume = false
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume()
                case .failed(let error):
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: error)
                    } else {
                        self.onClose?(error)
                    }
                case .cancelled:
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: SSH1Error.connectionCancelled)
                    }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    private func receiveChunk() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
            guard let connection else {
                continuation.resume(throwing: SSH1Error.connectionClosed)
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                    return
                }
                if isComplete {
                    continuation.resume(throwing: SSH1Error.connectionClosed)
                    return
                }
                continuation.resume(returning: [])
            }
        }
    }

    private func receiveExactly(_ count: Int) async throws -> [UInt8] {
        while inputBuffer.count < count {
            let chunk = try await receiveChunk()
            if !chunk.isEmpty {
                inputBuffer.append(contentsOf: chunk)
            }
        }
        let result = Array(inputBuffer.prefix(count))
        inputBuffer.removeFirst(count)
        return result
    }

    private func rawSend(_ data: Data) async throws {
        guard let connection else { throw SSH1Error.connectionClosed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func readVersionBanner() async throws -> String {
        var lineBytes: [UInt8] = []
        while true {
            let byte = try await receiveExactly(1)[0]
            if byte == UInt8(ascii: "\n") { break }
            if byte != UInt8(ascii: "\r") { lineBytes.append(byte) }
            if lineBytes.count > 256 {
                throw SSH1Error.protocolError("SSH-1 version banner was implausibly long.")
            }
        }
        return String(decoding: lineBytes, as: UTF8.self)
    }

    private func sendVersionBanner() async throws {
        try await rawSend(Data("SSH-1.5-MobaMac_1.0\r\n".utf8))
    }

    // MARK: - Packet framing
    //
    // uint32 packet_length (covers type+data+crc only; always sent/read in
    // the clear, even once bulk encryption is active) + padding (1-8 random
    // bytes, padding_length = 8 - (packet_length % 8)) + 1-byte type + data
    // + 4-byte CRC-32 of (padding+type+data). Once the session key packet
    // has been sent, (padding+type+data+crc) as a whole is what gets
    // encrypted/decrypted -- see SSH1Cipher.

    private func readPacket() async throws -> (type: UInt8, payload: [UInt8]) {
        let lengthBytes = try await receiveExactly(4)
        let packetLength = Int(Self.decodeUInt32(lengthBytes, at: 0))
        guard packetLength >= 5, packetLength <= 262_144 else {
            throw SSH1Error.protocolError("Implausible SSH-1 packet length \(packetLength).")
        }
        let paddingLength = 8 - (packetLength % 8)
        var blob = try await receiveExactly(paddingLength + packetLength)
        if let incomingCipher {
            blob = incomingCipher.decrypt(blob)
        }

        let type = blob[paddingLength]
        let dataLength = packetLength - 1 - 4
        let dataStart = paddingLength + 1
        let data = Array(blob[dataStart..<(dataStart + dataLength)])

        let coveredLength = paddingLength + 1 + dataLength
        let expectedCRC = SSH1CRC32.checksumBytes(Array(blob[0..<coveredLength]))
        let receivedCRC = Array(blob[coveredLength..<(coveredLength + 4)])
        guard receivedCRC == expectedCRC else {
            throw SSH1Error.protocolError("SSH-1 packet CRC mismatch -- the session is desynchronized (wrong cipher key, or corrupted stream).")
        }

        return (type, data)
    }

    private func writePacket(type: UInt8, data: [UInt8]) async throws {
        let packetLength = 1 + data.count + 4
        let paddingLength = 8 - (packetLength % 8)
        var body = Self.randomBytes(paddingLength)
        body.append(type)
        body.append(contentsOf: data)
        body.append(contentsOf: SSH1CRC32.checksumBytes(body))

        if let outgoingCipher {
            body = outgoingCipher.encrypt(body)
        }

        var wire = Self.encodeUInt32(UInt32(packetLength))
        wire.append(contentsOf: body)
        try await rawSend(Data(wire))
    }

    // MARK: - Wire-format primitives

    private static func encodeUInt32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private static func decodeUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func encodeString(_ bytes: [UInt8]) -> [UInt8] {
        encodeUInt32(UInt32(bytes.count)) + bytes
    }

    private static func decodeString(_ bytes: [UInt8], at offset: Int) -> (value: [UInt8], nextOffset: Int) {
        guard offset + 4 <= bytes.count else { return ([], bytes.count) }
        let length = Int(decodeUInt32(bytes, at: offset))
        let start = offset + 4
        let end = min(start + max(0, length), bytes.count)
        guard start <= end else { return ([], bytes.count) }
        return (Array(bytes[start..<end]), end)
    }

    /// SSH-1's own mpint format: a 2-byte **bit**-length prefix (not a byte
    /// length, unlike SSH-2's mpint), followed by the minimal big-endian
    /// value bytes.
    private static func encodeMPInt(_ valueBytes: [UInt8]) -> [UInt8] {
        var trimmed = valueBytes
        while trimmed.count > 1, trimmed.first == 0 {
            trimmed.removeFirst()
        }
        let bitLength: Int
        if trimmed == [0] {
            bitLength = 0
        } else {
            bitLength = (trimmed.count - 1) * 8 + (8 - Int(trimmed[0].leadingZeroBitCount))
        }
        return [UInt8((bitLength >> 8) & 0xff), UInt8(bitLength & 0xff)] + trimmed
    }

    private static func decodeMPInt(_ bytes: [UInt8], at offset: Int) throws -> SSH1MPIntResult {
        guard offset + 2 <= bytes.count else { throw SSH1Error.protocolError("Truncated SSH-1 mpint length.") }
        let bitLength = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
        let byteLength = (bitLength + 7) / 8
        let start = offset + 2
        let end = start + byteLength
        guard end <= bytes.count else { throw SSH1Error.protocolError("Truncated SSH-1 mpint value.") }
        return SSH1MPIntResult(bytes: Array(bytes[start..<end]), nextOffset: end)
    }

    private static func parsePublicKeyPacket(_ payload: [UInt8]) throws -> SSH1PublicKeyInfo {
        guard payload.count >= 8 else { throw SSH1Error.protocolError("SSH_SMSG_PUBLIC_KEY packet too short.") }
        let cookie = Array(payload[0..<8])
        var offset = 8

        let serverBits = decodeUInt32(payload, at: offset); offset += 4
        let serverExponent = try decodeMPInt(payload, at: offset); offset = serverExponent.nextOffset
        let serverModulus = try decodeMPInt(payload, at: offset); offset = serverModulus.nextOffset

        let hostBits = decodeUInt32(payload, at: offset); offset += 4
        let hostExponent = try decodeMPInt(payload, at: offset); offset = hostExponent.nextOffset
        let hostModulus = try decodeMPInt(payload, at: offset); offset = hostModulus.nextOffset

        guard offset + 12 <= payload.count else {
            throw SSH1Error.protocolError("SSH_SMSG_PUBLIC_KEY packet is missing its trailing fields.")
        }
        let protocolFlags = decodeUInt32(payload, at: offset); offset += 4
        let ciphersMask = decodeUInt32(payload, at: offset); offset += 4
        let authMask = decodeUInt32(payload, at: offset); offset += 4

        return SSH1PublicKeyInfo(
            cookie: cookie,
            serverKey: SSH1RSAKey(bits: serverBits, exponent: serverExponent.bytes, modulus: serverModulus.bytes),
            hostKey: SSH1RSAKey(bits: hostBits, exponent: hostExponent.bytes, modulus: hostModulus.bytes),
            protocolFlags: protocolFlags,
            supportedCiphersMask: ciphersMask,
            supportedAuthenticationsMask: authMask
        )
    }

    private static func computeSessionID(hostModulus: [UInt8], serverModulus: [UInt8], cookie: [UInt8]) -> [UInt8] {
        var input = hostModulus
        input.append(contentsOf: serverModulus)
        input.append(contentsOf: cookie)
        return Array(Insecure.MD5.hash(data: Data(input)))
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        return bytes
    }

    private static func randomNonZeroBytes(_ count: Int) -> [UInt8] {
        var bytes = randomBytes(count)
        for i in 0..<bytes.count {
            while bytes[i] == 0 {
                bytes[i] = randomBytes(1)[0]
            }
        }
        return bytes
    }

    /// PKCS#1 v1.5 type-2 (encryption) padding -- this is exactly the
    /// padding scheme the historical SSH-1 spec defines for its session-key
    /// RSA encryption: 0x00 0x02 <random non-zero bytes> 0x00 <message>,
    /// total length equal to the modulus's byte length.
    private static func pkcs1Pad(_ message: [UInt8], toByteLength k: Int) throws -> [UInt8] {
        guard message.count <= k - 11 else {
            throw SSH1Error.protocolError("RSA key too small to wrap \(message.count) bytes of session-key material (needs >= \(message.count + 11) bytes, key provides \(k)).")
        }
        var block: [UInt8] = [0x00, 0x02]
        block.append(contentsOf: randomNonZeroBytes(k - 3 - message.count))
        block.append(0x00)
        block.append(contentsOf: message)
        return block
    }

    private static func rsaPublicEncrypt(_ message: [UInt8], key: SSH1RSAKey) throws -> [UInt8] {
        let k = key.modulus.count
        let padded = try pkcs1Pad(message, toByteLength: k)
        let m = SSH1BigUInt(bigEndianBytes: padded)
        let e = SSH1BigUInt(bigEndianBytes: key.exponent)
        let n = SSH1BigUInt(bigEndianBytes: key.modulus)
        let c = SSH1BigUInt.modPow(base: m, exponent: e, modulus: n)
        var cBytes = c.toBigEndianBytes()
        if cBytes.count < k {
            cBytes = [UInt8](repeating: 0, count: k - cBytes.count) + cBytes
        }
        return cBytes
    }

    /// Whichever key has the SMALLER modulus is encrypted first, so its
    /// fixed-size ciphertext (exactly that modulus's byte length) is
    /// guaranteed short enough to fit as the plaintext for the second
    /// (larger-modulus) key's own PKCS#1 padding.
    private static func doubleRSAEncrypt(_ sessionKey: [UInt8], serverKey: SSH1RSAKey, hostKey: SSH1RSAKey) throws -> [UInt8] {
        let (first, second) = serverKey.modulus.count <= hostKey.modulus.count ? (serverKey, hostKey) : (hostKey, serverKey)
        let firstPass = try rsaPublicEncrypt(sessionKey, key: first)
        return try rsaPublicEncrypt(firstPass, key: second)
    }
}

private struct SSH1RSAKey {
    let bits: UInt32
    let exponent: [UInt8]
    let modulus: [UInt8]
}

private struct SSH1PublicKeyInfo {
    let cookie: [UInt8]
    let serverKey: SSH1RSAKey
    let hostKey: SSH1RSAKey
    let protocolFlags: UInt32
    let supportedCiphersMask: UInt32
    let supportedAuthenticationsMask: UInt32
}

private struct SSH1MPIntResult {
    let bytes: [UInt8]
    let nextOffset: Int
}
