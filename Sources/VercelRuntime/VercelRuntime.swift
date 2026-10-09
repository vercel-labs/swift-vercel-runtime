import Synchronization

/// Entry point for talking to the Vercel functions runtime from a native `executable` function.
///
/// The contract, implemented by Vercel's runtime layer on `provided.al2023`:
/// 1. The process is spawned with `VERCEL_IPC_PATH` set and must connect to that Unix socket.
/// 2. Once its HTTP server listens on `127.0.0.1`, it sends `server-started` with the port.
/// 3. Requests carry `x-vercel-internal-*` headers, which must be stripped before user code.
/// 4. Each request finishes with an `end` message, including on errors. `end` also marks the end
///    of the request's ``Vercel/waitUntil(_:)`` work.
/// 5. `GET /_vercel/ping` returns 200 and sends nothing.
///
/// Sending never blocks: messages are queued and written by ``IPCConnection`` on a SwiftNIO event
/// loop. When `VERCEL_IPC_PATH` is not set (local development) every method is a no-op.
public final class VercelRuntime: Sendable {
    /// The process-wide runtime, connected on first access. Access it as early as possible so
    /// `initDuration` covers application setup.
    public static let shared = VercelRuntime(ipcPath: environmentValue(ipcPathVariable))

    public static let ipcPathVariable = "VERCEL_IPC_PATH"

    /// `nil` when not running on Vercel, or when connecting failed.
    public let connection: IPCConnection?
    private let startedAt: ContinuousClock.Instant
    let requests = RequestRegistry()

    /// Whether the process is running under the Vercel functions runtime.
    public var isEnabled: Bool { connection != nil }

    public init(ipcPath: String?) {
        self.startedAt = .now
        guard let ipcPath, !ipcPath.isEmpty else {
            self.connection = nil
            return
        }
        let requests = self.requests
        do {
            self.connection = try IPCConnection(path: ipcPath) { message in
                requests.receive(message)
            }
        } catch {
            writeToStandardError("[vercel] failed to connect to IPC socket: \(error)")
            self.connection = nil
        }
    }

    /// Tells the runtime the HTTP server is ready on `127.0.0.1:httpPort`.
    public func serverStarted(httpPort: Int) {
        let elapsed = ContinuousClock.now - startedAt
        let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        guard let port = UInt16(exactly: httpPort) else {
            writeToStandardError("[vercel] invalid HTTP port \(httpPort)")
            connection?.send(.unrecoverableError(exitCode: 1, message: "invalid HTTP port \(httpPort)"))
            return
        }
        connection?.send(.serverStarted(initDuration: UInt64(max(0, milliseconds)), httpPort: port))
    }

    /// Runs one request's handler with the request contract applied.
    ///
    /// While `body` runs, ``Vercel/currentInvocation`` is set, logs from ``VercelLogHandler``
    /// are attributed to the request, and ``Vercel/waitUntil(_:)`` work is tracked. The `end`
    /// message is sent once `body` has returned or thrown and all `waitUntil` work finished. The
    /// response itself is not delayed.
    ///
    /// Framework adapters call this; you only need it to support another HTTP server.
    public func withRequest<T>(_ context: InvocationContext?, _ body: () async throws -> T) async rethrows -> T {
        guard isEnabled, let context else {
            return try await body()
        }
        let scope = RequestScope(context: context, runtime: self)
        requests.insert(scope)
        defer { scope.handlerFinished() }
        return try await Vercel.$currentScope.withValue(scope) {
            try await body()
        }
    }

    /// Marks a request as finished. Prefer ``withRequest(_:_:)``, which also waits for
    /// `waitUntil` work. Without `end` the runtime keeps the request open until it times out.
    public func requestEnded(_ context: InvocationContext) {
        connection?.send(.end(context, error: nil))
    }

    /// Sends a log line attributed to a request. Dropped (and counted) if the runtime is not
    /// reading fast enough, so logging can never stall request handling.
    public func log(_ message: String, level: IPCMessage.LogLevel, context: InvocationContext) {
        connection?.send(.log(context, message: message, level: level))
    }

    /// Reports a fatal error and waits until it has been written, since the process usually exits
    /// right after. The runtime stops routing traffic to this instance.
    public func unrecoverableError(exitCode: Int32 = 1, message: String) async {
        writeToStandardError(message)
        connection?.send(.unrecoverableError(exitCode: exitCode, message: message))
        await flush()
    }

    /// Waits until every message sent so far has been written to the socket.
    public func flush() async {
        await connection?.flush()
    }

    /// Writes any queued messages and closes the connection. Call at most once, at process exit.
    public func shutdown() async {
        await connection?.close()
    }

    func scopeEnded(_ scope: RequestScope) {
        requests.remove(scope)
        requestEnded(scope.context)
    }
}

/// In-flight requests, so messages from the runtime (like `approaching-timeout`) can reach them.
final class RequestRegistry: Sendable {
    private let scopes = Mutex<[InvocationContext: RequestScope]>([:])

    func insert(_ scope: RequestScope) {
        scopes.withLock { $0[scope.context] = scope }
    }

    func remove(_ scope: RequestScope) {
        scopes.withLock { scopes in
            if scopes[scope.context] === scope {
                scopes[scope.context] = nil
            }
        }
    }

    var count: Int {
        scopes.withLock { $0.count }
    }

    func receive(_ message: RuntimeMessage) {
        switch message {
        case .approachingTimeout(let context):
            let scope = scopes.withLock { $0[context] }
            scope?.cancelBackgroundWork()
        case .unknown:
            break
        }
    }
}

/// Header names used by the Vercel functions runtime.
public enum VercelHeader {
    public static let internalPrefix = "x-vercel-internal-"
    public static let invocationID = "x-vercel-internal-invocation-id"
    public static let requestID = "x-vercel-internal-request-id"
    public static let internalOIDCToken = "x-vercel-internal-oidc-token"
    /// Public OIDC header exposed to user code, derived from the internal one.
    public static let oidcToken = "x-vercel-oidc-token"

    /// Runtime cache configuration headers. `x-vercel-sc-runtime-cache` is always removed; the
    /// others are removed when the proxy sets ``runtimeCacheNoHeaderLeak``.
    public static let runtimeCache = "x-vercel-sc-runtime-cache"
    public static let runtimeCacheNoHeaderLeak = "x-vercel-sc-no-header-leak"
    public static let runtimeCacheConfiguration: Set<String> = [
        "x-vercel-sc-headers",
        "x-vercel-sc-host",
        "x-vercel-sc-basepath",
        "x-vercel-sc-protocol",
        runtimeCacheNoHeaderLeak,
    ]

    /// The health check path. Answer with 200 and send no IPC messages.
    public static let pingPath = "/_vercel/ping"

    /// Whether a lowercased header name is internal and must not reach user code.
    public static func isInternal(_ lowercasedName: String) -> Bool {
        lowercasedName.hasPrefix(internalPrefix)
    }
}
