#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import VercelHTTP

/// Reads a Vercel Global Config store (formerly Edge Config): a global, low-latency key-value
/// store for feature flags, redirects, allow lists and other configuration that changes without
/// a redeploy. Like `@vercel/edge-config`.
///
/// Connect a store to the project and Vercel sets the `EDGE_CONFIG` environment variable, which
/// ``default`` reads:
///
/// ```swift
/// import VercelGlobalConfig
///
/// // A feature flag.
/// let config = try GlobalConfig.default
/// if try await config.get("newCheckout", as: Bool.self) == true {
///     // ...
/// }
///
/// // A redirect map stored as {"redirects": {"/old": "/new"}}.
/// let redirects = try await config.get("redirects", as: [String: String].self) ?? [:]
/// if let destination = redirects[request.path] {
///     return .redirect(to: destination)
/// }
///
/// // Several items at once, decoded into your own type.
/// struct Flags: Decodable { var newCheckout: Bool?; var maintenance: Bool? }
/// let flags = try await config.getAll(keys: ["newCheckout", "maintenance"], as: Flags.self)
/// ```
///
/// Reads go to the store's HTTP API. On Vercel, when the deployment ships a snapshot of the store
/// (`/opt/edge-config/<id>.json`), reads are served from it without a request; pass
/// `consistentRead: true` to always read the latest value from the API instead.
///
/// Printing a client, `dump` and debug descriptions never show its token.
public struct GlobalConfig: Sendable {
    /// The environment variable ``default`` reads the connection string from: `EDGE_CONFIG`.
    public static let defaultEnvironmentVariable = "EDGE_CONFIG"

    /// The directory Vercel ships store snapshots in, as `<id>.json`.
    package static let defaultLocalDirectory = "/opt/edge-config"

    /// Seconds the store's CDN may serve a stale value when it fails to get a fresh one.
    package static let staleIfError = 604_800

    /// The store this client reads.
    public let connection: Connection
    /// How long each request may take.
    public var timeout: Duration

    private let client: VercelHTTPClient
    /// `VERCEL_ENV`, sent as `x-edge-config-vercel-env`. The header fields themselves are built
    /// for each request, so no copy of the token sits in them between requests.
    private let vercelEnvironment: String?
    /// The deployment's snapshot of the store, `nil` when it must not be used.
    private let localFilePath: String?

    /// A client for the store in `connectionString`. See
    /// ``Connection/init(connectionString:)`` for the supported forms.
    ///
    /// ```swift
    /// let config = try GlobalConfig(connectionString: "edge-config:id=ecfg_abc&token=secret")
    /// ```
    ///
    /// - Throws: ``GlobalConfigError/missingConnectionString`` or
    ///   ``GlobalConfigError/invalidConnectionString``.
    public init(connectionString: String, timeout: Duration = .seconds(10)) throws(GlobalConfigError) {
        try self.init(
            connectionString: connectionString,
            timeout: timeout,
            environment: ProcessInfo.processInfo.environment,
            client: VercelHTTPClient()
        )
    }

    /// A client using `client`, reading `VERCEL_ENV` and `AWS_LAMBDA_FUNCTION_NAME` from
    /// `environment` and snapshots from `localDirectory`, for tests.
    package init(
        connectionString: String,
        timeout: Duration = .seconds(10),
        environment: [String: String],
        client: VercelHTTPClient,
        localDirectory: String = GlobalConfig.defaultLocalDirectory
    ) throws(GlobalConfigError) {
        let connection = try Connection(connectionString: connectionString)
        self.connection = connection
        self.timeout = timeout
        self.client = client

        self.vercelEnvironment = environment["VERCEL_ENV"].flatMap { $0.isEmpty ? nil : $0 }

        // Vercel only ships snapshots of its own stores, and only inside functions.
        let isFunction = !(environment["AWS_LAMBDA_FUNCTION_NAME"] ?? "").isEmpty
        if connection.type == .vercel, isFunction {
            localFilePath = "\(localDirectory)/\(connection.id).json"
        } else {
            localFilePath = nil
        }
    }

    /// A client for the store in the environment variable `variable`.
    ///
    /// - Throws: ``GlobalConfigError/missingConnectionString`` when the variable is unset or empty,
    ///   ``GlobalConfigError/invalidConnectionString`` when its value cannot be parsed.
    public static func fromEnvironment(
        _ variable: String = GlobalConfig.defaultEnvironmentVariable,
        timeout: Duration = .seconds(10)
    ) throws(GlobalConfigError) -> GlobalConfig {
        try fromEnvironment(variable, timeout: timeout, environment: ProcessInfo.processInfo.environment, client: VercelHTTPClient())
    }

    package static func fromEnvironment(
        _ variable: String = GlobalConfig.defaultEnvironmentVariable,
        timeout: Duration = .seconds(10),
        environment: [String: String],
        client: VercelHTTPClient,
        localDirectory: String = GlobalConfig.defaultLocalDirectory
    ) throws(GlobalConfigError) -> GlobalConfig {
        try GlobalConfig(
            connectionString: environment[variable] ?? "",
            timeout: timeout,
            environment: environment,
            client: client,
            localDirectory: localDirectory
        )
    }

    /// A client for the store in `EDGE_CONFIG`, the variable Vercel sets when a store is connected
    /// to the project.
    ///
    /// ```swift
    /// let maintenance = try await GlobalConfig.default.get("maintenance", as: Bool.self) ?? false
    /// ```
    ///
    /// - Throws: ``GlobalConfigError/missingConnectionString`` when `EDGE_CONFIG` is unset or empty,
    ///   ``GlobalConfigError/invalidConnectionString`` when its value cannot be parsed.
    public static var `default`: GlobalConfig {
        get throws(GlobalConfigError) { try fromEnvironment() }
    }

    // MARK: - Reads

    /// The value of `key` decoded as `type`, or `nil` when the store has no such key (or `key` is
    /// empty).
    ///
    /// ```swift
    /// let enabled = try await config.get("newCheckout", as: Bool.self) ?? false
    /// let redirects: [String: String]? = try await config.get("redirects")
    /// ```
    ///
    /// - Parameter consistentRead: Read the latest value from the API, skipping the deployment's
    ///   snapshot and caches. Slower; use it only when a value must reflect a write made moments ago.
    /// - Throws: ``GlobalConfigError`` or `DecodingError` when the value does not decode as
    ///   `type`.
    public func get<T: Decodable>(_ key: String, as type: T.Type = T.self, consistentRead: Bool = false) async throws -> T? {
        guard !isEmptyKey(key) else { return nil }
        if !consistentRead, let local = localSnapshot() {
            return try local.items[key]?.decode(as: T.self)
        }
        let response = try await send(.get, "/item/\(percentEncoded(key))", consistentRead: consistentRead)
        switch response.status.code {
        case 200..<300:
            return try response.decode(T.self)
        case 401:
            throw GlobalConfigError.unauthorized
        case 404 where response.headerFields[.edgeConfigDigest] != nil:
            return nil
        case 404:
            throw GlobalConfigError.storeNotFound
        case let status:
            throw GlobalConfigError.unexpectedStatus(statusCode: status)
        }
    }

    /// The value of `key` as untyped JSON, or `nil` when the store has no such key.
    ///
    /// ```swift
    /// if let banner = try await config.get("banner"), banner["enabled"]?.boolValue == true { ... }
    /// ```
    public func get(_ key: String, consistentRead: Bool = false) async throws -> GlobalConfigValue? {
        try await get(key, as: GlobalConfigValue.self, consistentRead: consistentRead)
    }

    /// Whether the store has `key`, checked without downloading its value.
    ///
    /// ```swift
    /// let isBlocked = try await config.has("blocked:\(userID)")
    /// ```
    ///
    /// - Throws: ``GlobalConfigError``.
    public func has(_ key: String, consistentRead: Bool = false) async throws -> Bool {
        guard !isEmptyKey(key) else { return false }
        if !consistentRead, let local = localSnapshot() {
            return local.items[key] != nil
        }
        let response = try await send(.head, "/item/\(percentEncoded(key))", consistentRead: consistentRead)
        switch response.status.code {
        case 401:
            throw GlobalConfigError.unauthorized
        case 404 where response.headerFields[.edgeConfigDigest] != nil:
            return false
        case 404:
            throw GlobalConfigError.storeNotFound
        case 200..<300:
            return true
        case let status:
            throw GlobalConfigError.unexpectedStatus(statusCode: status)
        }
    }

    /// The items of the store, or only those in `keys`, decoded as `type`: a JSON object with one
    /// member per item. Keys the store doesn't have are left out.
    ///
    /// ```swift
    /// struct Flags: Decodable { var newCheckout: Bool?; var maintenance: Bool? }
    /// let flags = try await config.getAll(keys: ["newCheckout", "maintenance"], as: Flags.self)
    /// ```
    ///
    /// An empty `keys` list (after dropping empty keys) yields an empty object without a request.
    ///
    /// - Throws: ``GlobalConfigError`` or `DecodingError`.
    public func getAll<T: Decodable>(keys: [String]? = nil, as type: T.Type = T.self, consistentRead: Bool = false) async throws -> T {
        if !consistentRead, let local = localSnapshot() {
            let items = keys.map { keys in local.items.filter { keys.contains($0.key) } } ?? local.items
            return try GlobalConfigValue.object(items).decode(as: T.self)
        }
        var query: [(name: String, value: String)] = []
        if let keys {
            query = keys.filter { !isEmptyKey($0) }.map { ("key", $0) }
            if query.isEmpty {
                return try GlobalConfigValue.object([:]).decode(as: T.self)
            }
        }
        let response = try await send(.get, "/items", query: query, consistentRead: consistentRead)
        switch response.status.code {
        case 200..<300:
            return try response.decode(T.self)
        case 401:
            throw GlobalConfigError.unauthorized
        case 404:
            throw GlobalConfigError.storeNotFound
        case let status:
            throw GlobalConfigError.unexpectedStatus(statusCode: status)
        }
    }

    /// The items of the store, or only those in `keys`, as untyped JSON.
    ///
    /// ```swift
    /// let items = try await config.getAll()
    /// for (key, value) in items { print(key, value) }
    /// ```
    public func getAll(keys: [String]? = nil, consistentRead: Bool = false) async throws -> [String: GlobalConfigValue] {
        try await getAll(keys: keys, as: [String: GlobalConfigValue].self, consistentRead: consistentRead)
    }

    /// The store's digest: a hash that changes whenever any item changes. Useful as a cache key.
    ///
    /// - Throws: ``GlobalConfigError`` or `DecodingError`.
    public func digest(consistentRead: Bool = false) async throws -> String {
        if !consistentRead, let local = localSnapshot() {
            return local.digest
        }
        let response = try await send(.get, "/digest", consistentRead: consistentRead)
        switch response.status.code {
        case 200..<300:
            return try response.decode(String.self)
        case 401:
            throw GlobalConfigError.unauthorized
        case 404:
            throw GlobalConfigError.storeNotFound
        case let status:
            throw GlobalConfigError.unexpectedStatus(statusCode: status)
        }
    }

    // MARK: - Internals

    private func localSnapshot() -> LocalGlobalConfig? {
        localFilePath.flatMap(LocalGlobalConfig.load(path:))
    }

    private func send(
        _ method: HTTPRequest.Method,
        _ path: String,
        query: [(name: String, value: String)] = [],
        consistentRead: Bool
    ) async throws -> VercelHTTPResponse {
        var fields: HTTPFields = [
            .authorization: "Bearer \(connection.token)",
            .edgeConfigSDK: "swift-vercel-runtime@\(VercelLibrary.version)",
            .cacheControl: "stale-if-error=\(Self.staleIfError)",
        ]
        if let vercelEnvironment {
            fields[.edgeConfigVercelEnv] = vercelEnvironment
        }
        if consistentRead {
            // Number.MAX_SAFE_INTEGER: only a value updated after it would satisfy the read, so
            // the API skips every cache.
            fields[.edgeConfigMinUpdatedAt] = "9007199254740991"
        }
        let url = "\(connection.baseURL)\(path)?\(queryString([("version", connection.version)] + query))"
        do {
            return try await client.send(method, url, headerFields: fields, timeout: timeout)
        } catch let error as VercelHTTPError {
            if let timeout = error.timeout {
                throw GlobalConfigError.timedOut(timeout)
            }
            throw GlobalConfigError.requestFailed(error.description)
        }
    }
}

extension GlobalConfig: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Describes the client by its store, without the token.
    public var description: String {
        "GlobalConfig(connection: \(connection), timeout: \(timeout))"
    }

    public var debugDescription: String { description }

    /// The store and timeout for `dump` and debuggers, without the token.
    public var customMirror: Mirror {
        Mirror(self, children: ["connection": connection, "timeout": timeout], displayStyle: .struct)
    }
}

/// Whether `key` is empty or only whitespace, like `key.trim() === ""` in JavaScript.
private func isEmptyKey(_ key: String) -> Bool {
    key.allSatisfy(\.isWhitespace)
}

extension HTTPField.Name {
    static let edgeConfigSDK = HTTPField.Name("x-edge-config-sdk")!
    static let edgeConfigVercelEnv = HTTPField.Name("x-edge-config-vercel-env")!
    static let edgeConfigMinUpdatedAt = HTTPField.Name("x-edge-config-min-updated-at")!
    static let edgeConfigDigest = HTTPField.Name("x-edge-config-digest")!
}
