import Foundation

/// Decides what `swift package vercel init` does with `.swift-version` next to Package.swift.
///
/// The Install Command (scripts/vercel-install-swift.sh) installs the Swift release in that file,
/// and the latest release without it. Writing the local toolchain's version there deploys with the
/// Swift the project was developed with, so new Swift releases are opt-in. swiftly reads the same
/// file locally.
///
/// Kept free of `PackagePlugin` so the logic can be compiled and tested on its own.
enum SwiftVersionFile {
    static let name = ".swift-version"

    enum Action: Equatable {
        /// The file exists (with this version, trimmed) and is left as it is.
        case keep(String)
        /// Write this version to the file.
        case write(String)
        /// No version to write; the reason is a sentence fragment.
        case skip(reason: String)
    }

    /// - Parameters:
    ///   - existing: contents of `.swift-version`, or `nil` if there is none
    ///   - swiftVersionOutput: output of `swift --version`
    static func action(existing: String?, swiftVersionOutput: String) -> Action {
        if let existing {
            return .keep(existing.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // A swift.org release: exactly that release, like 6.4.0.
        if let release = ToolchainCheck.releaseVersion(in: swiftVersionOutput) {
            return .write(release)
        }
        // Apple's toolchain doesn't name its swift.org release: major.minor, like 6.4, which the
        // Install Command resolves to the latest 6.4.x.
        if let version = ToolchainCheck.appleVersion(in: swiftVersionOutput) {
            return .write(version)
        }
        let firstLine = swiftVersionOutput.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return .skip(reason: "`swift` is not a Swift release (\(firstLine))")
    }

    /// What `init` prints for `action`.
    static func message(for action: Action) -> String {
        switch action {
        case .keep(let version) where version.isEmpty:
            return "\(name) already exists but is empty, so it was left unchanged (Vercel builds use the latest Swift release)."
        case .keep(let version):
            return "\(name) already exists, so it was left unchanged (Swift \(version))."
        case .write(let version):
            let builds = version.split(separator: ".").count >= 3
                ? "Swift \(version)"
                : "the latest Swift \(version).x release"
            return "Wrote \(name) (\(version)): Vercel builds use \(builds), and swiftly uses it locally."
        case .skip(let reason):
            return """
                Did not write \(name): \(reason). Vercel builds use the latest Swift release unless \
                \(name) names one, like 6.4.0.
                """
        }
    }
}
