#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// `vercel-bootstrap.json`, written by the `vercel-build` plugin next to the bootstrap binary.
///
/// ```json
/// { "executable": "App", "crons": ["/cron/cleanup"] }
/// ```
package struct BootstrapConfiguration: Sendable, Equatable {
    package static let fileName = "vercel-bootstrap.json"

    /// The app's executable, relative to the function directory.
    package var executable: String
    /// Paths of the cron jobs from `vercel.json`, without query strings.
    package var cronPaths: Set<String>

    package init(executable: String, cronPaths: Set<String> = []) {
        self.executable = executable
        self.cronPaths = Set(cronPaths.map(normalizedPath))
    }

    package init(json: some Collection<UInt8>) throws {
        let file = try JSONDecoder().decode(ConfigurationFile.self, from: Data(json))
        guard !file.executable.isEmpty, !file.executable.utf8.contains(UInt8(ascii: "/")) else {
            throw BootstrapError("\(Self.fileName): `executable` must be a file name, got '\(file.executable)'")
        }
        self.init(executable: file.executable, cronPaths: Set(file.crons ?? []))
    }

    package static func load(directory: String) throws -> BootstrapConfiguration {
        let path = directory + "/" + fileName
        guard let contents = readFile(path) else {
            throw BootstrapError("cannot read \(path). Build the function with `swift package vercel-build`.")
        }
        return try BootstrapConfiguration(json: contents)
    }

    /// Whether `path` (a request target without its query) is one of the cron paths.
    package func isCronPath(_ path: some StringProtocol) -> Bool {
        !cronPaths.isEmpty && cronPaths.contains(normalizedPath(String(path)))
    }
}

private struct ConfigurationFile: Decodable {
    var executable: String
    var crons: [String]?
}

/// Drops the query and any trailing slash (except for `/`).
package func normalizedPath(_ target: String) -> String {
    var path = Substring(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    while path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    return path.isEmpty ? "/" : String(path)
}

package struct BootstrapError: Error, CustomStringConvertible {
    package var description: String

    package init(_ description: String) {
        self.description = description
    }
}
