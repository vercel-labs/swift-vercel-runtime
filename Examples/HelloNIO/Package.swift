// swift-tools-version: 6.4
import PackageDescription

// A plain SwiftNIO HTTP server with no Vercel code at all: the package only depends on
// swift-vercel-runtime for `swift package vercel`.
let package = Package(
    name: "NIOExample",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "NIOApp", targets: ["App"]),
    ],
    dependencies: [
        // In your app: .package(url: "https://github.com/vercel-labs/swift-vercel-runtime.git", from: "0.4.0")
        .package(name: "swift-vercel-runtime", path: "../.."),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
    ]
)
