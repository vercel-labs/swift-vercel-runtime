#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import VercelProtocol

/// `vercel-bootstrap.json`, written by the `vercel` plugin next to the bootstrap binary.
///
/// ```json
/// { "executable": "App", "crons": ["/cron/cleanup"] }
/// ```
package struct BootstrapConfiguration: Sendable, Equatable {
    package static let fileName = "vercel-bootstrap.json"

    /// The app's executable, relative to the function directory.
    package var executable: String
    /// Paths of the cron jobs from `vercel.json`, in the form ``cronMatchKey(_:)`` produces.
    package var cronPaths: Set<String>

    package init(executable: String, cronPaths: Set<String> = []) {
        self.executable = executable
        self.cronPaths = Set(cronPaths.map(cronMatchKey))
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
            throw BootstrapError("cannot read \(path). Build the function with `swift package vercel`.")
        }
        return try BootstrapConfiguration(json: contents)
    }

    /// Whether a request target may reach one of the cron routes.
    package func isCronPath(_ target: some StringProtocol) -> Bool {
        !cronPaths.isEmpty && cronPaths.contains(cronMatchKey(String(target)))
    }
}

private struct ConfigurationFile: Decodable {
    var executable: String
    var crons: [String]?
}

/// The form request targets and cron paths are compared in.
///
/// It errs on the side of matching, since a false match only means a `401` without the secret:
/// routers ignore empty segments (Hummingbird and Vapor route `//cron` and `/cron//` like
/// `/cron`), and some decode percent-encoding or match case-insensitively. So this drops the
/// scheme and authority of an absolute-form target, the query and fragment, and empty segments,
/// decodes percent-encoding, and lowercases.
package func cronMatchKey(_ target: String) -> String {
    var path = Substring(target)
    if !path.hasPrefix("/"), let scheme = path.utf8.indices.first(where: { index in
        path.utf8[index...].starts(with: "://".utf8)
    }) {
        // http://host/cron -> /cron
        let authority = path.utf8.index(scheme, offsetBy: 3)
        path = path.utf8[authority...].firstIndex(of: UInt8(ascii: "/")).map { path[$0...] } ?? "/"
    }
    if let end = path.utf8.firstIndex(where: { $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#") }) {
        path = path[..<end]
    }
    let segments = percentDecoded(String(path)).lowercased().split(separator: "/")
    return "/" + segments.joined(separator: "/")
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
