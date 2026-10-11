import HTTPTypes
import VercelHTTP
import VercelRuntime

/// The Vercel Runtime Cache service for one request's configuration. Mirrors `BuildCache` from
/// `@vercel/functions` (URLs, headers and status handling), except that failures throw.
struct RuntimeCacheService: Sendable {
    /// `x-vercel-cache-state`: whether a `200` response to a get is fresh.
    static let cacheStateHeader = "x-vercel-cache-state"
    static let revalidateHeader = "x-vercel-revalidate"
    static let cacheTagsHeader = "x-vercel-cache-tags"
    static let cacheItemNameHeader = "x-vercel-cache-item-name"
    static let clientOriginHeader = "x-vercel-internal-sc-client-origin"
    static let clientNameHeader = "x-vercel-internal-sc-client-name"
    static let clientIdentifier = "RUNTIME_CACHE"

    /// `{protocol}://{host}{basepath}/v1/suspense-cache/`.
    let baseURL: String
    /// `x-vercel-sc-headers` plus the client identification headers.
    let headerFields: HTTPFields
    let client: VercelHTTPClient
    let timeout: Duration
    /// The explicit headers of the request the cache is used for, to attribute fetch metrics.
    let requestHeaders: HTTPFields?

    init(configuration: RuntimeCacheConfiguration, client: VercelHTTPClient, timeout: Duration, requestHeaders: HTTPFields? = nil) {
        baseURL = "\(configuration.scheme)://\(configuration.host)\(configuration.basePath)/v1/suspense-cache/"
        var fields = HTTPFields()
        // Sorted so requests are deterministic; names that are not valid header names are skipped.
        for (name, value) in configuration.headers.sorted(by: { $0.key < $1.key }) {
            if let fieldName = HTTPField.Name(name) {
                fields[fieldName] = value
            }
        }
        fields.setValue(Self.clientIdentifier, for: Self.clientOriginHeader)
        fields.setValue(Self.clientIdentifier, for: Self.clientNameHeader)
        headerFields = fields
        self.client = client
        self.timeout = timeout
        self.requestHeaders = requestHeaders
    }

    /// `GET {base}{key}`: the JSON body of a fresh entry, `nil` for a missing (`404`) or not fresh
    /// one.
    func get(_ key: String) async throws -> [UInt8]? {
        let response = try await send(.get, .get, url: baseURL + pathEncoded(key))
        switch response.status.code {
        case 404:
            return nil
        case 200:
            guard let name = HTTPField.Name(Self.cacheStateHeader), response.headerFields[name] == "fresh" else {
                return nil
            }
            return response.body
        default:
            throw Self.unexpectedStatus(.get, response)
        }
    }

    /// `POST {base}{key}` with the JSON `value`.
    func set(_ key: String, value: [UInt8], ttl: Duration?, tags: [String], name: String?) async throws {
        var fields = headerFields
        if let ttl, ttl > .zero {
            fields.setValue(Self.seconds(ttl), for: Self.revalidateHeader)
        }
        if !tags.isEmpty {
            fields.setValue(tags.joined(separator: ","), for: Self.cacheTagsHeader)
        }
        if let name, !name.isEmpty {
            fields.setValue(name, for: Self.cacheItemNameHeader)
        }
        let response = try await send(.set, .post, url: baseURL + pathEncoded(key), headerFields: fields, body: value)
        try Self.expectOK(.set, response)
    }

    /// `DELETE {base}{key}`.
    func delete(_ key: String) async throws {
        let response = try await send(.delete, .delete, url: baseURL + pathEncoded(key))
        try Self.expectOK(.delete, response)
    }

    /// `POST {base}revalidate?tags=a,b`, each tag percent-encoded.
    func expireTags(_ tags: [String]) async throws {
        let query = tags.map(percentEncoded).joined(separator: ",")
        let response = try await send(.expireTag, .post, url: "\(baseURL)revalidate?tags=\(query)")
        try Self.expectOK(.expireTag, response)
    }

    private func send(
        _ operation: RuntimeCacheError.Operation,
        _ method: HTTPRequest.Method,
        url: String,
        headerFields: HTTPFields? = nil,
        body: [UInt8]? = nil
    ) async throws -> VercelHTTPResponse {
        do {
            return try await client.send(
                method,
                url,
                headerFields: headerFields ?? self.headerFields,
                body: body,
                timeout: timeout,
                incomingRequestHeaders: requestHeaders
            )
        } catch let error as VercelHTTPError {
            if let timeout = error.timeout {
                throw RuntimeCacheError.timedOut(timeout, operation: operation)
            }
            throw RuntimeCacheError.requestFailed(error.description, operation: operation)
        }
    }

    private static func expectOK(_ operation: RuntimeCacheError.Operation, _ response: VercelHTTPResponse) throws {
        guard response.status.code == 200 else { throw unexpectedStatus(operation, response) }
    }

    private static func unexpectedStatus(_ operation: RuntimeCacheError.Operation, _ response: VercelHTTPResponse) -> RuntimeCacheError {
        .unexpectedStatus(statusCode: response.status.code, operation: operation)
    }

    /// The TTL in seconds as JavaScript's `Number.prototype.toString` writes it (`60`, `1.5`,
    /// `0.001`), but never in exponent notation: `1e-7` is written `0.0000001`.
    static func seconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        if attoseconds == 0 {
            return String(seconds)
        }
        return plainDecimal(Double(seconds) + Double(attoseconds) / 1e18)
    }
}

extension HTTPFields {
    fileprivate mutating func setValue(_ value: String, for name: String) {
        if let fieldName = HTTPField.Name(name) {
            self[fieldName] = value
        }
    }
}

/// Encodes a key for the URL path like Node's `fetch` (`new URL()`) does, so both send the same
/// URL: the WHATWG path percent-encode set (C0 controls, space, `"`, `#`, `<`, `>`, `?`, `^`,
/// `` ` ``, `{`, `}`, and bytes from `0x7F`) is percent-encoded, `\` becomes `/` as in every
/// `https` URL, and everything else, including `%` and `|`, is kept. Unlike Node, `?` and `#`
/// are encoded rather than ending the path. Keys from the default hash and usual namespaces are
/// sent unchanged.
func pathEncoded(_ key: String) -> String {
    let digits = Array("0123456789ABCDEF".utf8)
    var output: [UInt8] = []
    output.reserveCapacity(key.utf8.count)
    for byte in key.utf8 {
        switch byte {
        case 0...0x20, 0x7F...0xFF, UInt8(ascii: "\""), UInt8(ascii: "#"), UInt8(ascii: "<"), UInt8(ascii: ">"),
            UInt8(ascii: "?"), UInt8(ascii: "^"), UInt8(ascii: "`"), UInt8(ascii: "{"), UInt8(ascii: "}"):
            output.append(UInt8(ascii: "%"))
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        case UInt8(ascii: "\\"):
            output.append(UInt8(ascii: "/"))
        default:
            output.append(byte)
        }
    }
    return String(decoding: output, as: UTF8.self)
}

/// `value` in decimal without an exponent, with the fewest digits that read back as `value`
/// (Swift's `description`, like JavaScript's `Number.prototype.toString`).
func plainDecimal(_ value: Double) -> String {
    let text = value.description
    guard let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }), let exponent = Int(text[text.index(after: e)...]) else {
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
    var mantissa = text[..<e]
    let negative = mantissa.hasPrefix("-")
    if negative { mantissa = mantissa.dropFirst() }
    // Digits without the point, and where the point was.
    let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    var digits = String(parts[0]) + (parts.count > 1 ? String(parts[1]) : "")
    let point = parts[0].count + exponent
    while digits.count > 1, digits.hasSuffix("0") { digits.removeLast() }
    let result: String
    if point <= 0 {
        result = "0." + String(repeating: "0", count: -point) + digits
    } else if point >= digits.count {
        result = digits + String(repeating: "0", count: point - digits.count)
    } else {
        let index = digits.index(digits.startIndex, offsetBy: point)
        result = digits[..<index] + "." + digits[index...]
    }
    return negative ? "-" + result : result
}
