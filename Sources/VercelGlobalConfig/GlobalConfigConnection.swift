import HTTPTypes
import VercelHTTP

extension GlobalConfig {
    /// A parsed Global Config connection string: where the store lives and how to authenticate.
    ///
    /// ```swift
    /// let connection = try GlobalConfig.Connection(connectionString: "edge-config:id=ecfg_abc&token=secret")
    /// connection.id      // "ecfg_abc"
    /// connection.baseURL // "https://edge-config.vercel.com/ecfg_abc"
    /// ```
    ///
    /// Printing a connection, `dump` and debug descriptions leave out ``token``.
    public struct Connection: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        /// Who hosts the store.
        public enum Kind: String, Sendable, Hashable {
            /// A store hosted by Vercel (`edge-config.vercel.com`).
            case vercel
            /// A store reached through any other URL.
            case external
        }

        /// Who hosts the store.
        public var type: Kind
        /// The store ID, for example `ecfg_abc123`.
        public var id: String
        /// The URL every request path is appended to, without a query.
        public var baseURL: String
        /// The read access token. Keep it secret: descriptions of the connection leave it out.
        public var token: String
        /// The API version sent as the `version` query parameter.
        public var version: String

        /// Parses a connection string, in this order:
        ///
        /// 1. `edge-config:id=<id>&token=<token>`
        /// 2. `https://edge-config.vercel.com/<ecfg_id>?token=<token>`
        /// 3. Any other URL with a `token` query parameter and either an `id` query parameter or the
        ///    ID as its first path segment (`https://example.com/ecfg_abc?token=…&version=1`). The
        ///    base URL is the URL without its query; `version` defaults to `1`.
        ///
        /// The first two forms are Vercel-hosted stores; the third is an external one.
        ///
        /// - Throws: ``GlobalConfigError/missingConnectionString`` when `connectionString` is empty,
        ///   ``GlobalConfigError/invalidConnectionString`` when it matches none of the forms.
        public init(connectionString: String) throws(GlobalConfigError) {
            guard !connectionString.isEmpty else { throw .missingConnectionString }
            guard let connection = Self.parse(connectionString) else { throw .invalidConnectionString }
            self = connection
        }

        /// A connection from its parts.
        public init(type: Kind, id: String, baseURL: String, token: String, version: String = "1") {
            self.type = type
            self.id = id
            self.baseURL = baseURL
            self.token = token
            self.version = version
        }

        /// Describes the connection without its token (or credentials in an external base URL).
        public var description: String {
            "GlobalConfig.Connection(type: \(type.rawValue), id: \(id), baseURL: \(redactingUserInfo(baseURL)), version: \(version))"
        }

        public var debugDescription: String { description }

        /// The connection for `dump` and debuggers, with the token redacted.
        public var customMirror: Mirror {
            Mirror(
                self,
                children: ["type": type, "id": id, "baseURL": redactingUserInfo(baseURL), "token": "<redacted>", "version": version],
                displayStyle: .struct
            )
        }

        static func parse(_ text: String) -> Connection? {
            fromQueryParameters(text) ?? fromVercelURL(text) ?? fromExternalURL(text)
        }

        /// `edge-config:id=<id>&token=<token>`
        private static func fromQueryParameters(_ text: String) -> Connection? {
            let prefix = "edge-config:"
            guard text.hasPrefix(prefix) else { return nil }
            let parameters = FormParameters(String(text.dropFirst(prefix.count)))
            guard let id = parameters["id"], !id.isEmpty, let token = parameters["token"], !token.isEmpty else {
                return nil
            }
            return Connection(type: .vercel, id: id, baseURL: vercelBaseURL(id), token: token)
        }

        /// `https://edge-config.vercel.com/<ecfg_id>?token=<token>`
        private static func fromVercelURL(_ text: String) -> Connection? {
            guard let url = URLParts(text), url.scheme == "https", url.host == "edge-config.vercel.com",
                url.path.hasPrefix("/ecfg"), let id = url.firstPathSegment,
                let token = url.parameters["token"], !token.isEmpty
            else { return nil }
            return Connection(type: .vercel, id: id, baseURL: vercelBaseURL(id), token: token)
        }

        /// Any other URL with a token and an ID.
        private static func fromExternalURL(_ text: String) -> Connection? {
            guard let url = URLParts(text) else { return nil }
            var id = url.parameters["id"].flatMap { $0.isEmpty ? nil : $0 }
            if id == nil || url.path.hasPrefix("/ecfg_") {
                id = url.firstPathSegment
            }
            guard let id, let token = url.parameters["token"], !token.isEmpty else { return nil }
            let version = url.parameters["version"].flatMap { $0.isEmpty ? nil : $0 } ?? "1"
            return Connection(
                type: .external,
                id: id,
                baseURL: "\(url.scheme)://\(url.authority)\(url.path)",
                token: token,
                version: version
            )
        }

        private static func vercelBaseURL(_ id: String) -> String {
            "https://edge-config.vercel.com/\(id)"
        }
    }
}

/// The parts of an absolute URL that connection strings use.
private struct URLParts {
    var scheme: String
    var authority: String
    /// The path without the query, starting with `/`.
    var path: String
    var parameters: FormParameters

    init?(_ text: String) {
        guard let request = try? HTTPRequest(method: .get, urlString: text), let scheme = request.scheme,
            let authority = request.authority
        else { return nil }
        let (path, query) = request.pathAndQuery
        self.scheme = scheme
        self.authority = authority
        self.path = path
        self.parameters = FormParameters(query ?? "")
    }

    /// The host, lowercased, with the default port for the scheme removed.
    var host: String {
        let host = authority.lowercased()
        let defaultPort = scheme == "https" ? ":443" : scheme == "http" ? ":80" : nil
        if let defaultPort, host.hasSuffix(defaultPort) {
            return String(host.dropLast(defaultPort.count))
        }
        return host
    }

    /// The first path segment, `nil` when it is empty.
    var firstPathSegment: String? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count > 1, !segments[1].isEmpty else { return nil }
        return String(segments[1])
    }
}

/// `application/x-www-form-urlencoded` parameters, decoded like `URLSearchParams`: `+` is a space
/// and invalid percent escapes are kept as they are.
struct FormParameters {
    private var pairs: [(name: String, value: String)] = []

    init(_ query: String) {
        for part in query.split(separator: "&") {
            let name: Substring
            let value: Substring
            if let equals = part.firstIndex(of: "=") {
                name = part[..<equals]
                value = part[part.index(after: equals)...]
            } else {
                name = part
                value = ""
            }
            pairs.append((formDecoded(name), formDecoded(value)))
        }
    }

    /// The first value for `name`.
    subscript(_ name: String) -> String? {
        pairs.first { $0.name == name }?.value
    }
}

private func formDecoded(_ text: Substring) -> String {
    let bytes = Array(text.utf8)
    var output: [UInt8] = []
    output.reserveCapacity(bytes.count)
    var index = 0
    while index < bytes.count {
        let byte = bytes[index]
        if byte == UInt8(ascii: "+") {
            output.append(UInt8(ascii: " "))
        } else if byte == UInt8(ascii: "%"), index + 2 < bytes.count,
            let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2])
        {
            output.append(high << 4 | low)
            index += 2
        } else {
            output.append(byte)
        }
        index += 1
    }
    return String(decoding: output, as: UTF8.self)
}

private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
    default: nil
    }
}
