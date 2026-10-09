import Foundation

/// Preflight checks for cross-compiling with the Static Linux SDK.
///
/// Without these, the common setup mistakes (building with Apple's toolchain, a missing SDK, or an
/// SDK for another Swift version) surface after a minute of compiling as pages of
/// "compiled module was created by a different version of the compiler" errors.
///
/// Kept free of `PackagePlugin` so the logic can be compiled and tested on its own.
enum ToolchainCheck {
    static let installGuide = "https://www.swift.org/install/macos/"

    /// Returns a message describing the problem, or `nil` when the build can go ahead.
    ///
    /// - Parameters:
    ///   - swiftVersionOutput: output of `swift --version`
    ///   - sdkListOutput: output of `swift sdk list`, or `nil` to skip the SDK checks
    ///     (used when the user picked an SDK explicitly)
    static func problem(swiftVersionOutput: String, sdkListOutput: String?) -> String? {
        // Apple's toolchains (Xcode, Command Line Tools) identify as "(swiftlang-6.4.0.34.1 ...)";
        // swift.org toolchains as "(swift-6.4-RELEASE)". The Static Linux SDK only works with the
        // swift.org toolchain of the same version.
        if swiftVersionOutput.contains("(swiftlang-") {
            return """
                The Static Linux SDK needs a swift.org toolchain, but `swift` is Apple's toolchain \
                (Xcode or Command Line Tools):

                    \(firstLine(of: swiftVersionOutput))

                Install the swift.org toolchain with swiftly, then run this command again:

                    swiftly install 6.4.0
                    swiftly use 6.4.0

                Get swiftly at \(installGuide)
                """
        }

        guard let sdkListOutput else { return nil }
        let staticSDKs = sdkListOutput.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("static-linux") }
        let version = releaseVersion(in: swiftVersionOutput)

        if staticSDKs.isEmpty {
            return """
                The Swift Static Linux SDK is not installed (`swift sdk list` shows none).

                \(installInstructions(for: version))
                """
        }

        // Only release toolchains can be matched to an SDK by version; snapshots are left alone.
        if let version, !staticSDKs.contains(where: { $0.hasPrefix("swift-\(version)-RELEASE_static-linux") }) {
            return """
                The installed Static Linux SDK does not match the toolchain (Swift \(version)):

                    \(staticSDKs.joined(separator: "\n    "))

                \(installInstructions(for: version))
                """
        }
        return nil
    }

    /// `6.4` from "(swift-6.4-RELEASE)", normalized to three components (`6.4.0`) like SDK names.
    static func releaseVersion(in swiftVersionOutput: String) -> String? {
        guard let start = swiftVersionOutput.range(of: "(swift-"),
            let end = swiftVersionOutput.range(of: "-RELEASE)", range: start.upperBound..<swiftVersionOutput.endIndex)
        else { return nil }
        var components = swiftVersionOutput[start.upperBound..<end.lowerBound].split(separator: ".").map(String.init)
        guard (2...3).contains(components.count), components.allSatisfy({ Int($0) != nil }) else { return nil }
        while components.count < 3 { components.append("0") }
        return components.joined(separator: ".")
    }

    private static func installInstructions(for version: String?) -> String {
        guard let version else {
            return "Install the Static Linux SDK that matches your toolchain: \(installGuide)"
        }
        let url = "https://download.swift.org/swift-\(version)-release/static-sdk/swift-\(version)-RELEASE/swift-\(version)-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
        return """
            Install the Static Linux SDK for Swift \(version) ("Swift SDK for Static Linux" at \
            \(installGuide) has the command with its checksum):

                swift sdk install \(url) --checksum <checksum>
            """
    }

    private static func firstLine(of text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first ?? "")
    }
}
