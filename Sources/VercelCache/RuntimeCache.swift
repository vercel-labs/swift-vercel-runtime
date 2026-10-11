#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif
public import HTTPTypes
import Logging
import VercelHTTP
import VercelRuntime

/// The Vercel Runtime Cache: a key-value cache shared by every instance of a function in a
/// region, with TTLs and tag invalidation. Like `getCache()` from `@vercel/functions`, and
/// compatible with it: Swift and Node functions using the same keys and namespace share entries.
///
/// Values are any `Codable` type, stored as JSON with ``encoder`` and read with ``decoder``. By
/// default, dates are stored the way Node's `JSON.stringify` writes them: ISO 8601 in UTC with
/// milliseconds, like `2026-10-11T17:00:00.123Z` (`Date.prototype.toJSON()`), and read with or
/// without fractional seconds, so Swift and Node share entries that contain dates. Pass your own
/// `encoder:` and `decoder:` for other formats. Vercel passes the cache's location with each
/// request, so use the cache while handling one: inside ``Vercel/withRequest(_:_:)``, or pass the
/// request's headers explicitly.
///
/// ```swift
/// struct User: Codable { var id: Int; var name: String }
///
/// let cache = RuntimeCache(namespace: "users")
/// try await cache.set("user:1", user, ttl: .seconds(60), tags: ["users"])
/// let user = try await cache.get("user:1", as: User.self)
/// try await cache.delete("user:1")
/// try await cache.expireTag("users")
///
/// // Outside `Vercel.withRequest`, with the request's headers:
/// let cache = RuntimeCache(namespace: "users", headers: request.headers)
/// ```
///
/// When the Runtime Cache is not available, for example locally or outside a request on Vercel,
/// operations use a process-wide in-memory cache with the same semantics instead, and log a
/// warning once.
///
/// Unlike Node, which logs failures and returns `null`, operations throw
/// ``RuntimeCacheError`` when the cache answers with an error status, does not answer in time or
/// cannot be reached. Requests time out after 500 ms, or the number of milliseconds in the
/// `RUNTIME_CACHE_TIMEOUT` environment variable. Treat the cache as optional, for example with
/// `try?`, so a cache outage does not fail the request.
public struct RuntimeCache: Sendable {
    /// The separator between the namespace and the hashed key: `$`.
    public static let defaultNamespaceSeparator = "$"
    /// How long a request to the cache may take unless `RUNTIME_CACHE_TIMEOUT` says otherwise.
    public static let defaultTimeout: Duration = .milliseconds(500)

    /// Prefixes every key, followed by ``namespaceSeparator``. `nil` or empty for none.
    public var namespace: String?
    /// Separates ``namespace`` from the hashed key. Empty means ``defaultNamespaceSeparator``.
    public var namespaceSeparator: String
    /// Turns a key into the key stored in the cache. ``defaultKeyHash(_:)`` by default.
    public var keyHashFunction: @Sendable (String) -> String
    /// The headers of the request the cache is used for. `nil` uses ``Vercel/currentRequest``.
    ///
    /// They carry the cache's credentials, so printing, `dump` and debug descriptions of a cache
    /// leave them out.
    public var headers: HTTPFields?
    /// Encodes values to store. ``defaultEncoder`` by default.
    public var encoder: JSONEncoder
    /// Decodes stored values. ``defaultDecoder`` by default.
    public var decoder: JSONDecoder

    package var client: VercelHTTPClient
    package var timeout: Duration
    package var fallback: InMemoryRuntimeCache
    package var logger: Logger

    /// A cache for the current request, or for the request with `headers`.
    ///
    /// - Parameters:
    ///   - namespace: Prefixes every key, so caches with different namespaces never collide.
    ///   - namespaceSeparator: Separates the namespace from the hashed key, `$` by default.
    ///   - keyHashFunction: Turns a key into the key stored in the cache. Defaults to
    ///     ``defaultKeyHash(_:)``, the same hash as Node; change it only if no Node function
    ///     shares the entries.
    ///   - headers: The headers of the request to use the cache for. Defaults to the request of
    ///     ``Vercel/withRequest(_:_:)``.
    ///   - encoder: Encodes values to store. Defaults to ``defaultEncoder``, which writes dates
    ///     like Node. Customize a copy of it to keep Node compatibility:
    ///     `let encoder = RuntimeCache.defaultEncoder; encoder.keyEncodingStrategy = ...`.
    ///   - decoder: Decodes stored values. Defaults to ``defaultDecoder``, which reads dates
    ///     written by Node.
    public init(
        namespace: String? = nil,
        namespaceSeparator: String = RuntimeCache.defaultNamespaceSeparator,
        keyHashFunction: (@Sendable (String) -> String)? = nil,
        headers: HTTPFields? = nil,
        encoder: JSONEncoder = RuntimeCache.defaultEncoder,
        decoder: JSONDecoder = RuntimeCache.defaultDecoder
    ) {
        self.init(
            namespace: namespace,
            namespaceSeparator: namespaceSeparator,
            keyHashFunction: keyHashFunction,
            headers: headers,
            encoder: encoder,
            decoder: decoder,
            client: VercelHTTPClient(),
            timeout: Self.configuredTimeout,
            fallback: .shared
        )
    }

    /// A cache that sends its requests with `client` and falls back to `fallback`, for tests.
    package init(
        namespace: String? = nil,
        namespaceSeparator: String = RuntimeCache.defaultNamespaceSeparator,
        keyHashFunction: (@Sendable (String) -> String)? = nil,
        headers: HTTPFields? = nil,
        encoder: JSONEncoder = RuntimeCache.defaultEncoder,
        decoder: JSONDecoder = RuntimeCache.defaultDecoder,
        client: VercelHTTPClient,
        timeout: Duration = RuntimeCache.defaultTimeout,
        fallback: InMemoryRuntimeCache = InMemoryRuntimeCache(),
        logger: Logger = Logger(label: "vercel.cache")
    ) {
        self.namespace = namespace
        self.namespaceSeparator = namespaceSeparator
        self.keyHashFunction = keyHashFunction ?? Self.defaultKeyHash
        self.headers = headers
        self.encoder = encoder
        self.decoder = decoder
        self.client = client
        self.timeout = timeout
        self.fallback = fallback
        self.logger = logger
    }

    /// The value stored under `key`, or `nil` when there is none or it is no longer fresh.
    ///
    /// ```swift
    /// let user = try await cache.get("user:1", as: User.self)
    /// ```
    ///
    /// - Throws: ``RuntimeCacheError`` when the cache fails, `DecodingError` when ``decoder``
    ///   cannot decode the stored value as a `Value`.
    public func get<Value: Decodable>(_ key: String, as type: Value.Type = Value.self) async throws -> Value? {
        let storageKey = storageKey(for: key)
        let json: [UInt8]?
        switch await backend() {
        case .service(let service):
            json = try await service.get(storageKey)
        case .memory(let memory):
            json = memory.get(storageKey)
        }
        guard let json else { return nil }
        return try decoder.decode(Value.self, from: Data(json))
    }

    /// Stores `value` under `key`.
    ///
    /// ```swift
    /// try await cache.set("user:1", user, ttl: .seconds(60), tags: ["users"])
    /// ```
    ///
    /// - Parameters:
    ///   - key: The key, hashed with ``keyHashFunction`` and prefixed with ``namespace``.
    ///   - value: The value, stored as JSON encoded with ``encoder``.
    ///   - ttl: How long the value stays fresh. `nil` (or not positive) leaves it to the cache. In
    ///     the in-memory fallback, like Node's, `nil` and zero never expire and a negative TTL
    ///     expires the value right away.
    ///   - tags: Tags to expire the value with ``expireTag(_:)-(String)``.
    ///   - name: A readable name for the entry in Vercel's observability. Defaults to `key`; pass
    ///     `""` to send none.
    /// - Throws: ``RuntimeCacheError`` when the cache fails, `EncodingError` when `value` cannot be
    ///   encoded.
    public func set<Value: Encodable>(
        _ key: String,
        _ value: Value,
        ttl: Duration? = nil,
        tags: [String] = [],
        name: String? = nil
    ) async throws {
        let storageKey = storageKey(for: key)
        let json = Array(try encoder.encode(value))
        switch await backend() {
        case .service(let service):
            try await service.set(storageKey, value: json, ttl: ttl, tags: tags, name: name ?? key)
        case .memory(let memory):
            memory.set(storageKey, value: json, ttl: ttl, tags: tags)
        }
    }

    /// Removes the value stored under `key`, if any.
    ///
    /// - Throws: ``RuntimeCacheError`` when the cache fails.
    public func delete(_ key: String) async throws {
        let storageKey = storageKey(for: key)
        switch await backend() {
        case .service(let service):
            try await service.delete(storageKey)
        case .memory(let memory):
            memory.delete(storageKey)
        }
    }

    /// Expires every value set with `tag`.
    ///
    /// Tags are global: they are not namespaced, so this expires matching values in every
    /// namespace.
    ///
    /// - Throws: ``RuntimeCacheError`` when the cache fails.
    public func expireTag(_ tag: String) async throws {
        try await expireTag([tag])
    }

    /// Expires every value set with any of `tags`. Does nothing for an empty array.
    ///
    /// - Throws: ``RuntimeCacheError`` when the cache fails.
    public func expireTag(_ tags: [String]) async throws {
        guard !tags.isEmpty else { return }
        switch await backend() {
        case .service(let service):
            try await service.expireTags(tags)
        case .memory(let memory):
            memory.expireTags(tags)
        }
    }

    private enum Backend {
        case service(RuntimeCacheService)
        case memory(InMemoryRuntimeCache)
    }

    /// The Runtime Cache service of the request, or the in-memory cache without one.
    private func backend() async -> Backend {
        if let configuration = await RuntimeCacheConfiguration.resolve(headers: headers) {
            return .service(RuntimeCacheService(configuration: configuration, client: client, timeout: timeout, requestHeaders: headers))
        }
        if fallback.shouldWarnUnavailable() {
            logger.warning("Runtime Cache unavailable in this environment. Falling back to in-memory cache.")
        }
        return .memory(fallback)
    }
}

extension RuntimeCache {
    /// A new encoder that writes values like Node's `JSON.stringify`: dates as ISO 8601 in UTC
    /// with milliseconds (`2026-10-11T17:00:00.123Z`) and `/` unescaped. Each access returns a new
    /// instance, so customizing it changes nothing else.
    public static var defaultEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = JavaScriptDate.encodingStrategy
        return encoder
    }

    /// A new decoder that reads dates as RFC 3339 / ISO 8601 strings, with or without fractional
    /// seconds, such as `2026-10-11T17:00:00.123Z` from Node's `JSON.stringify`. Each access
    /// returns a new instance.
    public static var defaultDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = JavaScriptDate.decodingStrategy
        return decoder
    }
}

extension RuntimeCache: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Describes the cache without its request headers, which carry the cache's credentials.
    public var description: String {
        let namespace = namespace.map { "\"\($0)\"" } ?? "nil"
        return "RuntimeCache(namespace: \(namespace), namespaceSeparator: \"\(namespaceSeparator)\", "
            + "timeout: \(timeout), headers: \(headers == nil ? "nil" : "<redacted>"))"
    }

    public var debugDescription: String { description }

    /// The cache's settings for `dump` and debuggers, without its request headers.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "namespace": namespace as Any,
                "namespaceSeparator": namespaceSeparator,
                "timeout": timeout,
                "headers": headers == nil ? "nil" : "<redacted>",
            ],
            displayStyle: .struct
        )
    }
}

extension RuntimeCache {
    /// ``defaultTimeout``, or `RUNTIME_CACHE_TIMEOUT` milliseconds when set to a positive number.
    static let configuredTimeout: Duration = {
        guard let value = ProcessInfo.processInfo.environment["RUNTIME_CACHE_TIMEOUT"] else {
            return defaultTimeout
        }
        guard let timeout = timeout(milliseconds: value) else {
            Logger(label: "vercel.cache").warning(
                "Invalid RUNTIME_CACHE_TIMEOUT value: \"\(value)\". Using default: 500ms"
            )
            return defaultTimeout
        }
        return timeout
    }()

    /// Parses a timeout in milliseconds like Node's `parseInt(value, 10)`: leading whitespace, an
    /// optional sign and the leading digits, ignoring the rest. `nil` unless positive.
    static func timeout(milliseconds value: String) -> Duration? {
        var bytes = Substring(value).utf8.drop { $0 == UInt8(ascii: " ") || (0x09...0x0D).contains($0) }
        var negative = false
        if let sign = bytes.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
            negative = sign == UInt8(ascii: "-")
            bytes = bytes.dropFirst()
        }
        let digits = bytes.prefix { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        guard !negative, !digits.isEmpty else { return nil }
        var milliseconds: Int64 = 0
        for digit in digits {
            let (times10, overflow1) = milliseconds.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = times10.addingReportingOverflow(Int64(digit - UInt8(ascii: "0")))
            guard !overflow1, !overflow2 else { return nil }
            milliseconds = sum
        }
        return milliseconds > 0 ? .milliseconds(milliseconds) : nil
    }
}
