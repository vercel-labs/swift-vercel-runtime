// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "VaporExample",
    platforms: [
        .macOS("26.2"),
    ],
    products: [
        .executable(name: "VaporApp", targets: ["App"]),
    ],
    dependencies: [
        // In your app: .package(url: "https://github.com/vercel-labs/swift-vercel-runtime.git", from: "0.4.0")
        .package(name: "swift-vercel-runtime", path: "../.."),
        .package(url: "https://github.com/vapor/vapor.git", from: "5.0.0-beta.3"),
        // Vapor 5.0.0-beta.3 resolves swift-http-server 0.3.0, which fails to compile against the
        // Static Linux SDK (musl) because of swiftlang/swift#92476. This revision is exactly 0.3.0
        // plus the upstream fix "Fix musl build (#138)". Revision pins are only allowed in the root
        // package, so apps need this line until a tagged swift-http-server release includes it.
        .package(
            url: "https://github.com/swift-server/swift-http-server.git",
            revision: "09ee2e3682248532c43975b1af5938628efb7ba8"
        ),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                // Optional: per-request logs, waitUntil and request helpers.
                .product(name: "VercelRuntime", package: "swift-vercel-runtime"),
                // Optional: the Vercel Runtime Cache. Add only the feature modules you use, or all of
                // them with the "Vercel" product.
                .product(name: "VercelCache", package: "swift-vercel-runtime"),
            ]
        ),
    ]
)
