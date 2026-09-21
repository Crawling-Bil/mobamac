// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MobaMac",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // Terminal emulation engine + AppKit front-end (feed bytes in, get keystrokes out).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMajor(from: "1.2.5")),
        // Pure-Swift SSH client (async/await) built on swift-nio-ssh.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", .upToNextMajor(from: "0.7.0")),
        // Serial port access for the Console/Serial session type — IOKit-backed,
        // the standard choice for Swift/macOS serial per the PRD's own notes.
        .package(url: "https://github.com/armadsen/ORSSerialPort.git", from: "2.1.0"),
        // Local, patched copy of the swift-nio-ssh fork Citadel uses. Same
        // package identity as Citadel's remote dependency, so this copy
        // replaces it throughout the graph. It accepts "SSH-1.99" version
        // banners (Cisco IOS, PAN-OS default), which upstream rejects. See
        // Vendor/swift-nio-ssh/VENDORED.md.
        .package(path: "Vendor/swift-nio-ssh")
    ],
    targets: [
        // Shim exposing Apple's CommonCrypto (DES/3DES) to Swift -- needed
        // for the legacy SSH-1 fallback client, which has to speak the
        // ciphers SSH-1-only gear actually offers (swift-crypto deliberately
        // doesn't expose DES at all, not even under its Insecure namespace).
        .systemLibrary(name: "CCommonCrypto", path: "Sources/CCommonCrypto"),
        .executableTarget(
            name: "MobaMac",
            dependencies: [
                "SwiftTerm",
                "Citadel",
                .product(name: "ORSSerial", package: "ORSSerialPort"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                "CCommonCrypto"
            ],
            path: "Sources/MobaMac",
            // Manifest needs tools-version 6.0 for .macOS(.v15) above, but the
            // source itself is written against Swift 5 semantics (plain
            // classes, unstructured `Task { }` closures) — Swift 6's default
            // strict concurrency checking would require a much larger rewrite
            // (Sendable conformances throughout) for no functional benefit on
            // a single-user desktop app. Pin the language mode explicitly
            // instead of fighting the checker file by file.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
