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
        // The Static Linux SDK only works with the swift.org toolchain of the same version.
        if isAppleToolchain(swiftVersionOutput) {
            // swiftly resolves a major.minor version to its latest patch release.
            let version = appleVersion(in: swiftVersionOutput) ?? "latest"
            return """
                The Static Linux SDK needs a swift.org toolchain, but `swift` is Apple's toolchain \
                (Xcode or Command Line Tools):

                    \(firstLine(of: swiftVersionOutput))

                Install the swift.org toolchain with swiftly, then run this command again:

                    swiftly install \(version)
                    swiftly use \(version)

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
        if let version, !staticSDKs.contains(where: { sdkReleaseVersion($0) == version }) {
            return """
                The installed Static Linux SDK does not match the toolchain (Swift \(version)):

                    \(staticSDKs.joined(separator: "\n    "))

                \(installInstructions(for: version))
                """
        }
        return nil
    }

    /// Whether `swift --version` is from Apple's toolchains (Xcode, Command Line Tools), which
    /// identify as "(swiftlang-6.4.0.34.1 ...)"; swift.org toolchains identify as "(swift-6.4-RELEASE)".
    static func isAppleToolchain(_ swiftVersionOutput: String) -> Bool {
        swiftVersionOutput.contains("(swiftlang-")
    }

    /// The major.minor version of Apple's toolchain, like `6.4` from
    /// "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-...)", or `nil` for other toolchains.
    static func appleVersion(in swiftVersionOutput: String) -> String? {
        guard isAppleToolchain(swiftVersionOutput),
            let start = swiftVersionOutput.range(of: "Apple Swift version ")
        else { return nil }
        let word = swiftVersionOutput[start.upperBound...].prefix { !$0.isWhitespace }
        let components = word.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, components.allSatisfy({ Int($0) != nil }) else { return nil }
        return components.prefix(2).joined(separator: ".")
    }

    /// The release of a swift.org toolchain, like `6.4.0` from "(swift-6.4-RELEASE)", normalized to
    /// three components; `nil` for snapshots and other toolchains.
    static func releaseVersion(in swiftVersionOutput: String) -> String? {
        guard let start = swiftVersionOutput.range(of: "(swift-"),
            let end = swiftVersionOutput.range(of: "-RELEASE)", range: start.upperBound..<swiftVersionOutput.endIndex)
        else { return nil }
        return normalized(swiftVersionOutput[start.upperBound..<end.lowerBound])
    }

    /// The release a Static Linux SDK is for, like `6.4.0` from "swift-6.4.0-RELEASE_static-linux-0.1.0"
    /// or "swift-6.3-RELEASE_static-linux-0.1.0" (`6.3.0`).
    static func sdkReleaseVersion(_ sdkID: String) -> String? {
        guard sdkID.hasPrefix("swift-"), let end = sdkID.range(of: "-RELEASE_static-linux") else { return nil }
        return normalized(sdkID[sdkID.index(sdkID.startIndex, offsetBy: 6)..<end.lowerBound])
    }

    /// `6.4` -> `6.4.0`, so versions compare equal however a release is named.
    private static func normalized(_ version: Substring) -> String? {
        var components = version.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(components.count), components.allSatisfy({ Int($0) != nil }) else { return nil }
        while components.count < 3 { components.append("0") }
        return components.joined(separator: ".")
    }

    private static func installInstructions(for version: String?) -> String {
        guard let version else {
            return "Install the Static Linux SDK that matches your toolchain: \(installGuide)"
        }
        return """
            Install the Static Linux SDK for Swift \(version) with the `swift sdk install` command (with \
            its checksum) under "Swift SDK for Static Linux" at \(installGuide)
            """
    }

    private static func firstLine(of text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first ?? "")
    }
}
