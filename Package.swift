// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GlassFTP",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "GlassFTP", targets: ["GlassFTP"])
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
        // Already resolved through Citadel; declared so the proxy code can
        // import NIOPosix for its own bootstrap.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.3")
    ],
    targets: [
        .executableTarget(
            name: "GlassFTP",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ],
            path: "Sources/GlassFTP",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
