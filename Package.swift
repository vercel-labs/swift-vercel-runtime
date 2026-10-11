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
        // Vercel Runtime Cache: a shared key-value cache with TTLs and tag invalidation.
        .library(name: "VercelCache", targets: ["VercelCache"]),
        // Vercel Global Config (formerly Edge Config): low-latency reads of a global data store.
        .library(name: "VercelGlobalConfig", targets: ["VercelGlobalConfig"]),
        // Vercel Firewall: rate limiting rules from your code.
        .library(name: "VercelFirewall", targets: ["VercelFirewall"]),
        // Vercel OIDC tokens: exchange them and get AWS credentials without long-lived secrets.
        .library(name: "VercelOIDC", targets: ["VercelOIDC"]),
        // Everything above in one import.
        .library(name: "Vercel", targets: ["Vercel"]),
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
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.35.0"),
    ],
    targets: [
        // Internal: the IPC protocol and helpers shared by the bootstrap and VercelRuntime. Keeps
        // VercelBootstrap, which ships in every function, independent of VercelRuntime.
        .target(
            name: "VercelProtocol",
            dependencies: [
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "VercelRuntime",
            dependencies: [
                "VercelProtocol",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        // Internal: the small HTTP layer the feature modules share, over AsyncHTTPClient. Only the
        // feature modules depend on it, so VercelRuntime and the bootstrap stay free of it.
        .target(
            name: "VercelHTTP",
            dependencies: [
                "VercelRuntime",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "VercelCache",
            dependencies: [
                "VercelRuntime",
                "VercelHTTP",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "VercelGlobalConfig",
            dependencies: [
                "VercelRuntime",
                "VercelHTTP",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "VercelFirewall",
            dependencies: [
                "VercelRuntime",
                "VercelHTTP",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "VercelOIDC",
            dependencies: [
                "VercelRuntime",
                "VercelHTTP",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings
        ),
        // `import Vercel`: re-exports VercelRuntime and every feature module.
        .target(
            name: "Vercel",
            dependencies: ["VercelRuntime", "VercelCache", "VercelGlobalConfig", "VercelFirewall", "VercelOIDC"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "VercelBootstrapCore",
            dependencies: [
                "VercelProtocol",
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
                "VercelProtocol",
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
        .testTarget(
            name: "VercelHTTPTests",
            dependencies: [
                "VercelHTTP",
                "VercelRuntime",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "VercelCacheTests",
            dependencies: [
                "VercelCache",
                // MockHTTPTransport.
                "VercelHTTP",
                "VercelRuntime",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "VercelGlobalConfigTests",
            dependencies: [
                "VercelGlobalConfig",
                // MockHTTPTransport.
                "VercelHTTP",
                "VercelRuntime",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "VercelFirewallTests",
            dependencies: [
                "VercelFirewall",
                // MockHTTPTransport.
                "VercelHTTP",
                "VercelRuntime",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "VercelOIDCTests",
            dependencies: [
                "VercelOIDC",
                // MockHTTPTransport.
                "VercelHTTP",
                "VercelRuntime",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
