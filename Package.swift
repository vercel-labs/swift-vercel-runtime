// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
]

let package = Package(
    name: "swift-vercel-runtime",
    platforms: [
        // `Mutex` from the Synchronization module.
        .macOS(.v15),
    ],
    products: [
        // Optional Vercel features for any Swift server: per-request logs, waitUntil, request
        // helpers, environment.
        .library(name: "VercelRuntime", targets: ["VercelRuntime"]),
        // The function entrypoint: runs your server and speaks Vercel's runtime protocol for it.
        // Built and deployed by `swift package vercel`; you never depend on it directly.
        .executable(name: "VercelBootstrap", targets: ["VercelBootstrap"]),
        // `swift package --disable-sandbox vercel`
        .plugin(name: "VercelPlugin", targets: ["VercelPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.0"),
    ],
    targets: [
        .target(
            name: "VercelRuntime",
            dependencies: [
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "VercelBootstrapCore",
            dependencies: [
                "VercelRuntime",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "VercelBootstrap",
            dependencies: ["VercelBootstrapCore"],
            swiftSettings: swiftSettings
        ),
        .plugin(
            name: "VercelPlugin",
            capability: .command(
                intent: .custom(
                    verb: "vercel",
                    description: "Cross-compile an executable with the Swift Static Linux SDK and write Vercel Build Output API files to .vercel/output."
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "Writes the compiled function to .vercel/output and build files to .build/vercel."),
                ]
            )
        ),
        .testTarget(
            name: "VercelRuntimeTests",
            dependencies: [
                "VercelRuntime",
                "VercelBootstrapCore",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
