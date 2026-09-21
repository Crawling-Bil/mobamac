// swift-tools-version:5.10
//
// Vendored copy of the swift-nio-ssh fork Citadel depends on
// (https://github.com/Wellz26/swift-nio-ssh, 0.3.6, a05e6bbe6b), cut down to
// the NIOSSH library target and patched to accept "SSH-1.99" version
// banners. See VENDORED.md for why this exists and exactly what changed.
//
// Because MobaMac's root Package.swift declares this as a local path
// dependency with the same package identity ("swift-nio-ssh"), SwiftPM uses
// it in place of the remote fork everywhere in the graph, Citadel included.

import PackageDescription

let package = Package(
    name: "swift-nio-ssh",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .watchOS(.v6),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "NIOSSH", targets: ["NIOSSH"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"4.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "NIOSSH",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
            ]
        )
    ]
)
