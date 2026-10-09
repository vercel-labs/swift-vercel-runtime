// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
]

let package = Package(
    name: "swift-vercel-runtime",
    platforms: [
        // Required by Vapor 5.
        .macOS("26.2"),
    ],
    products: [
        // Vercel functions runtime protocol. Use directly to support any Swift HTTP server.
        .library(name: "VercelRuntime", targets: ["VercelRuntime"]),
        // Framework adapters. SwiftPM only resolves the framework for the adapter you use.
        .library(name: "VercelVapor", targets: ["VercelVapor"]),
        .library(name: "VercelHummingbird", targets: ["VercelHummingbird"]),
        .library(name: "VercelHummingbirdWebSocket", targets: ["VercelHummingbirdWebSocket"]),
        // `swift package --disable-sandbox vercel-build`
        .plugin(name: "VercelBuildPlugin", targets: ["VercelBuildPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.0.0", traits: ["CommandLineArguments"]),
        .package(url: "https://github.com/vapor/vapor.git", from: "5.0.0-beta.3"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.8.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
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
            name: "VercelVapor",
            dependencies: [
                "VercelRuntime",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "VercelHummingbird",
            dependencies: [
                "VercelRuntime",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "VercelHummingbirdWebSocket",
            dependencies: [
                "VercelHummingbird",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .plugin(
            name: "VercelBuildPlugin",
            capability: .command(
                intent: .custom(
                    verb: "vercel-build",
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
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
