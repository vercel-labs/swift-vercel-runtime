#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
package import HTTPTypes
import VercelProtocol

/// Where the Vercel Runtime Cache for a request lives and how to authenticate with it.
///
/// Vercel passes it to every request as `x-vercel-sc-*` headers. When the proxy asks to keep them
/// out of the request (`x-vercel-sc-no-header-leak`), `VercelBootstrap` hides them from the app and
/// hands them over its socket instead; ``resolve(headers:)`` handles both.
package struct RuntimeCacheConfiguration: Sendable, Hashable {
    /// `x-vercel-sc-host`.
    package var host: String
    /// `x-vercel-sc-basepath`, `""` by default.
    package var basePath: String
    /// `x-vercel-sc-protocol`, `https` by default.
    package var scheme: String
    /// `x-vercel-sc-headers`: headers to send with every cache request.
    package var headers: [String: String]

    package init(host: String, basePath: String = "", scheme: String = "https", headers: [String: String]) {
        self.host = host
        self.basePath = basePath
        self.scheme = scheme
        self.headers = headers
    }

    /// Builds the configuration from `x-vercel-sc-*` values keyed by lowercased header name.
    /// Returns `nil` without a host or when `x-vercel-sc-headers` is not a JSON object.
    ///
    /// Header values are read leniently, like the Python runtime's `str()` coercion: strings as
    /// they are, numbers and booleans as their JSON text (`1`, `true`); `null`, arrays and objects
    /// skip that header.
    package init?(fields: [String: String]) {
        guard let host = fields[VercelHeader.runtimeCacheHost], !host.isEmpty,
            let json = fields[VercelHeader.runtimeCacheHeaders],
            let values = try? JSONDecoder().decode([String: LenientHeaderValue].self, from: Data(json.utf8))
        else { return nil }
        let headers = values.compactMapValues(\.text)
        let basePath = fields[VercelHeader.runtimeCacheBasePath] ?? ""
        let scheme = fields[VercelHeader.runtimeCacheProtocol].flatMap { $0.isEmpty ? nil : $0 } ?? "https"
        self.init(host: host, basePath: basePath, scheme: scheme, headers: headers)
    }

    /// The configuration for the request with these headers (by default ``Vercel/currentRequest``):
    /// from its headers when present, else from the bootstrap. `nil` when neither has one, for
    /// example locally.
    package static func resolve(headers: HTTPFields? = nil) async -> RuntimeCacheConfiguration? {
        RuntimeCacheConfiguration(fields: await fields(headers: headers))
    }

    /// The raw `x-vercel-sc-*` values for the request with these headers (by default
    /// ``Vercel/currentRequest``), keyed by lowercased header name: from its headers when they
    /// carry `x-vercel-sc-host`, else asked from the bootstrap. Empty when neither has them.
    ///
    /// For the current request (inside ``Vercel/withRequest(_:_:)`` under the bootstrap) the
    /// bootstrap's answer is remembered, so only the first cache operation of a request asks.
    /// Explicit headers of another request ask every time.
    static func fields(headers: HTTPFields? = nil) async -> [String: String] {
        let context = Vercel.currentContext
        guard let request = headers ?? context?.headers else { return [:] }
        let visible = fields(in: request)
        if visible[VercelHeader.runtimeCacheHost]?.isEmpty == false {
            return visible
        }
        let token = HTTPField.Name(BootstrapProtocol.requestHeader).flatMap { request[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        // Only the bootstrap knows hidden values. The current request's scope asks it once. A
        // nested `withRequest` whose headers lack the token still belongs to the outer request.
        if let scope = context?.scope, token.map({ $0 == scope.token }) ?? (headers == nil) {
            return await scope.runtimeCacheFields()
        }
        // Connecting is fine here: the request came through the bootstrap.
        guard let token, let client = BootstrapClient.shared else { return visible }
        return await client.runtimeCacheFields(token: token)
    }

    /// The `x-vercel-sc-*` configuration values present in `headers`.
    static func fields(in headers: HTTPFields) -> [String: String] {
        var fields: [String: String] = [:]
        for name in VercelHeader.runtimeCacheFields {
            if let fieldName = HTTPField.Name(name), let value = headers[fieldName] {
                fields[name] = value
            }
        }
        return fields
    }
}

/// One `x-vercel-sc-headers` value: its text for strings, numbers and booleans, `nil` for anything
/// else.
private struct LenientHeaderValue: Decodable {
    var text: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
        } else if let bool = try? container.decode(Bool.self) {
            text = bool ? "true" : "false"
        } else if let integer = try? container.decode(Int64.self) {
            text = String(integer)
        } else if let number = try? container.decode(Double.self), number.isFinite {
            text = String(number)
        } else {
            // `null`, arrays and objects.
            text = nil
        }
    }
}
