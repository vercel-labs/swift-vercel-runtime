// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HummingbirdExample",
    platforms: [
        .macOS("26.2"),
    ],
    products: [
        .executable(name: "HummingbirdApp", targets: ["App"]),
    ],
    dependencies: [
        // In your app: .package(url: "https://github.com/vercel-labs/swift-vercel-runtime.git", from: "0.2.0")
        .package(name: "swift-vercel-runtime", path: "../.."),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                // Optional: per-request logs, waitUntil and request helpers.
                .product(name: "VercelRuntime", package: "swift-vercel-runtime"),
            ]
        ),
    ]
)
