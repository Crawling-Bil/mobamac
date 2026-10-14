// MobaMac addition, not part of upstream swift-nio-ssh. See VENDORED.md.
//
// RSA host keys verified with SHA-2 signatures, "rsa-sha2-256" and
// "rsa-sha2-512" (RFC 8332). The key itself is the same "ssh-rsa" key, so
// its blob and fingerprint do not change; only the signature over the
// exchange hash uses SHA-256 or SHA-512 instead of SHA-1.
//
// Network devices that turn SHA-1 off (current Cisco IOS XE and NX-OS,
// Aruba CX, anything built on OpenSSH 8.8 or later) offer only these two
// names for their RSA key. Without them a client that knows RSA only as
// "ssh-rsa" has no host key algorithm in common with the device.
//
// The RSA public key type is registered from outside (Citadel registers
// one with the prefix "ssh-rsa"), so verification here does not depend on
// that type. It reads the exponent and modulus back from the key's own
// wire format and verifies with the Security framework, which accepts the
// 1024-bit keys older switches still carry.

import Foundation
import NIOCore
#if canImport(Security)
import Security
#endif

/// An RSA signature made with SHA-256 or SHA-512.
protocol RSASHA2Signature: NIOSSHSignatureProtocol {
    var blob: Data { get }
    static var hashBits: Int { get }
}

struct RSASHA256Signature: RSASHA2Signature {
    static let signaturePrefix = "rsa-sha2-256"
    static let hashBits = 256
    let blob: Data

    var rawRepresentation: Data { self.blob }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(self.blob)
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA256Signature {
        guard let blob = buffer.readSSHString() else {
            throw NIOSSHError.invalidSSHMessage(reason: "rsa-sha2-256 signature is truncated")
        }
        return RSASHA256Signature(blob: Data(blob.readableBytesView))
    }
}

struct RSASHA512Signature: RSASHA2Signature {
    static let signaturePrefix = "rsa-sha2-512"
    static let hashBits = 512
    let blob: Data

    var rawRepresentation: Data { self.blob }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(self.blob)
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA512Signature {
        guard let blob = buffer.readSSHString() else {
            throw NIOSSHError.invalidSSHMessage(reason: "rsa-sha2-512 signature is truncated")
        }
        return RSASHA512Signature(blob: Data(blob.readableBytesView))
    }
}

enum RSASHA2 {
    static let rsaKeyPrefix = "ssh-rsa"

    /// Offered in this order: SHA-512 first, as OpenSSH does.
    static let hostKeyAlgorithms: [Substring] = [
        Substring(RSASHA512Signature.signaturePrefix),
        Substring(RSASHA256Signature.signaturePrefix),
    ]

    /// The key type a host key algorithm name stands for, when the two
    /// differ. "rsa-sha2-512" is an algorithm; the key it uses is "ssh-rsa".
    static func keyPrefix(forHostKeyAlgorithm algorithm: Substring) -> String? {
        self.hostKeyAlgorithms.contains(algorithm) ? self.rsaKeyPrefix : nil
    }

    /// Reads the signature body when `identifier` names one of the two
    /// algorithms, nil otherwise so other readers can try.
    static func readSignature(identifier: ByteBufferView, from buffer: inout ByteBuffer) throws -> RSASHA2Signature? {
        if identifier.elementsEqual(RSASHA256Signature.signaturePrefix.utf8) {
            return try RSASHA256Signature.read(from: &buffer)
        }
        if identifier.elementsEqual(RSASHA512Signature.signaturePrefix.utf8) {
            return try RSASHA512Signature.read(from: &buffer)
        }
        return nil
    }

    /// True when `signature` is a valid PKCS #1 v1.5 signature of `message`
    /// under the RSA public key `key`. `message` is the exchange hash, which
    /// SSH signs as a message: it is hashed again with SHA-256 or SHA-512.
    static func verify(_ signature: RSASHA2Signature, by key: NIOSSHPublicKeyProtocol, over message: Data) -> Bool {
        guard key.publicKeyPrefix == self.rsaKeyPrefix else { return false }

        // "ssh-rsa" key body: mpint e, then mpint n.
        var keyBytes = ByteBufferAllocator().buffer(capacity: 1024)
        _ = key.write(to: &keyBytes)
        guard let exponent = keyBytes.readSSHString(), let modulus = keyBytes.readSSHString() else {
            return false
        }

        #if canImport(Security)
        let der = self.pkcs1PublicKey(
            modulus: Array(modulus.readableBytesView),
            exponent: Array(exponent.readableBytesView)
        )
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, &error) else {
            return false
        }
        let algorithm: SecKeyAlgorithm = type(of: signature).hashBits == 512
            ? .rsaSignatureMessagePKCS1v15SHA512
            : .rsaSignatureMessagePKCS1v15SHA256
        return SecKeyVerifySignature(secKey, algorithm, message as CFData, signature.blob as CFData, &error)
        #else
        return false
        #endif
    }

    /// DER for PKCS #1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }.
    static func pkcs1PublicKey(modulus: [UInt8], exponent: [UInt8]) -> [UInt8] {
        let body = self.derInteger(modulus) + self.derInteger(exponent)
        return [0x30] + self.derLength(body.count) + body
    }

    private static func derInteger(_ bytes: [UInt8]) -> [UInt8] {
        var value = Array(bytes.drop(while: { $0 == 0 }))
        if value.isEmpty { value = [0] }
        if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return [0x02] + self.derLength(value.count) + value
    }

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}
