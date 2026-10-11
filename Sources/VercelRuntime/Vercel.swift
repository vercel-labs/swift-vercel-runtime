#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif
public import HTTPTypes
import Logging
import Synchronization
import VercelProtocol

/// Optional Vercel features for request handlers.
///
/// Your server does not need any of this to run on Vercel: `VercelBootstrap` already answers
/// health checks, strips the runtime's internal headers and reports every request. Use these
/// APIs for the features that need to know which request your code is running for.
public enum Vercel {
    /// The request the current task is handling, set by ``withRequest(_:_:)``.
    @TaskLocal static var currentContext: RequestContext?

    /// The current request's connection to the bootstrap. `nil` outside ``withRequest(_:_:)``,
    /// locally, or for requests that did not come through Vercel.
    static var currentScope: RequestScope? {
        currentContext?.scope
    }

    /// The request being handled, inside ``withRequest(_:_:)``. `nil` outside it.
    ///
    /// Lets code deep in a request find its headers without passing them around, like
    /// `getContext().headers` in `@vercel/functions`:
    ///
    /// ```swift
    /// let city = Vercel.currentRequest?.geolocation.city
    /// ```
    public static var currentRequest: VercelRequestInfo? {
        currentContext.map { VercelRequestInfo(headers: $0.headers) }
    }

    /// When the Vercel functions runtime will stop the current request (its maximum duration).
    /// `nil` outside ``withRequest(_:_:)`` or when not running on Vercel. See
    /// ``VercelRequestInfo/deadline``.
    public static var deadline: Date? {
        currentRequest?.deadline
    }

    /// Runs `body` as part of the request with these headers.
    ///
    /// Optional. While `body` runs, ``currentRequest`` returns this request, ``VercelLogHandler``
    /// attributes logs to the request in Vercel's logs (with their level, even with many
    /// concurrent requests) and ``waitUntil(_:)`` keeps the function alive for background work.
    /// Without it, logs still reach Vercel through standard output and error, just not tied to a
    /// request, and ``waitUntil(for:_:)`` still works. Call it from a middleware to cover every
    /// route:
    ///
    /// ```swift
    /// // Vapor
    /// struct VercelRequestMiddleware: Middleware {
    ///     func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
    ///         try await Vercel.withRequest(request.headers) { try await next.respond(to: request) }
    ///     }
    /// }
    /// ```
    ///
    /// Locally, or for requests that did not come through Vercel, it only sets ``currentRequest``.
    /// Nested inside another `withRequest` with headers that do not identify a request (for
    /// example rewritten headers), it keeps the outer request for logs and `waitUntil`.
    public static func withRequest<T>(_ headers: HTTPFields, _ body: () async throws -> T) async rethrows -> T {
        let scope = scope(for: headers) ?? currentScope
        return try await $currentContext.withValue(RequestContext(headers: headers, scope: scope)) {
            try await body()
        }
    }

    /// Keeps the function running until `operation` finishes, after the response is sent.
    ///
    /// Use it for work that should not delay the response, like analytics, cache warming or
    /// webhooks. The request is only reported finished once every `waitUntil` operation has
    /// completed, so the instance is not frozen mid-work. Operations are cancelled when the
    /// request approaches its maximum duration, so check `Task.isCancelled` in long work.
    ///
    /// Call it inside ``withRequest(_:_:)``, or use ``waitUntil(for:_:)``. Outside a request, or
    /// when not running on Vercel, the operation simply runs in a new task.
    public static func waitUntil(_ operation: @escaping @Sendable () async throws -> Void) {
        if let scope = currentScope {
            scope.waitUntil(operation)
        } else {
            Task { await runReportingErrors(operation) }
        }
    }

    /// Keeps the function running until `operation` finishes, after the response for the request
    /// with these headers is sent. Works without ``withRequest(_:_:)``:
    ///
    /// ```swift
    /// router.post("signup") { request, _ in
    ///     Vercel.waitUntil(for: request.headers) {
    ///         try await analytics.track("signup")
    ///     }
    ///     return "ok"
    /// }
    /// ```
    public static func waitUntil(for headers: HTTPFields, _ operation: @escaping @Sendable () async throws -> Void) {
        guard let scope = scope(for: headers) else {
            waitUntil(operation)
            return
        }
        $currentContext.withValue(RequestContext(headers: headers, scope: scope)) {
            scope.waitUntil(operation)
        }
    }

    /// Reports an outbound HTTP request made while handling the current request, so it shows up in
    /// Vercel's Observability under External APIs.
    ///
    /// Call it after the response arrives, inside ``withRequest(_:_:)``. Does nothing outside a
    /// request or when not running on Vercel.
    ///
    /// ```swift
    /// let clock = ContinuousClock()
    /// let started = clock.now
    /// let response = try await client.execute(request)
    /// Vercel.reportFetch(
    ///     method: "GET", host: "api.example.com", path: "/v1/users", query: "page=2",
    ///     statusCode: Int(response.status.code), duration: clock.now - started
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - method: The HTTP method, for example `GET`.
    ///   - host: The host the request went to, for example `api.example.com`.
    ///   - path: The URL path, for example `/v1/users`.
    ///   - query: The query string, with or without the leading `?`.
    ///   - statusCode: The response status code.
    ///   - start: When the request started. Defaults to `duration` before now.
    ///   - duration: How long the request took.
    public static func reportFetch(
        method: String,
        host: String,
        path: String,
        query: String? = nil,
        statusCode: Int,
        start: Date? = nil,
        duration: Duration
    ) {
        reportFetch(method: method, host: host, path: path, query: query, statusCode: statusCode, start: start, duration: duration, headers: nil)
    }

    /// ``reportFetch(method:host:path:query:statusCode:start:duration:)`` for the current request
    /// or, outside ``withRequest(_:_:)``, for the request with `headers`: the feature modules
    /// report requests made with explicit `headers:` this way. Does nothing when neither came
    /// through the bootstrap.
    package static func reportFetch(
        method: String,
        host: String,
        path: String,
        query: String? = nil,
        statusCode: Int,
        start: Date? = nil,
        duration: Duration,
        headers: HTTPFields?
    ) {
        reportFetch(
            method: method, host: host, path: path, query: query, statusCode: statusCode, start: start,
            duration: duration, headers: headers, bootstrap: BootstrapClient.shared
        )
    }

    /// Where a fetch metric goes: the current scope, else the bootstrap with the request token in
    /// `headers`. Doesn't create a scope for the token, so a late report can't leave one behind;
    /// `bootstrap` is only evaluated when `headers` carry a token.
    static func fetchMetricTarget(
        headers: HTTPFields?,
        bootstrap: @autoclosure () -> BootstrapClient?
    ) -> (client: BootstrapClient, token: String)? {
        if let scope = currentScope {
            return (scope.client, scope.token)
        }
        guard let headers, let name = HTTPField.Name(BootstrapProtocol.requestHeader),
            let token = headers[name], !token.isEmpty,
            let client = bootstrap()
        else { return nil }
        return (client, token)
    }

    static func reportFetch(
        method: String,
        host: String,
        path: String,
        query: String?,
        statusCode: Int,
        start: Date?,
        duration: Duration,
        headers: HTTPFields?,
        bootstrap: @autoclosure () -> BootstrapClient?
    ) {
        guard let target = fetchMetricTarget(headers: headers, bootstrap: bootstrap()) else { return }
        let durationMilliseconds = milliseconds(duration)
        let startMilliseconds: UInt64
        if let start {
            startMilliseconds = unixMilliseconds(start)
        } else {
            let now = unixMilliseconds(Date())
            startMilliseconds = now - min(now, durationMilliseconds)
        }
        var search = query ?? ""
        if search.hasPrefix("?") { search.removeFirst() }
        let metric = FetchMetric(
            id: 0,
            method: method,
            host: host,
            pathname: path.isEmpty ? "/" : path,
            search: search,
            statusCode: UInt16(clamping: statusCode),
            start: startMilliseconds,
            duration: durationMilliseconds
        )
        target.client.fetchMetric(metric, token: target.token)
    }

    /// Whether the app was started by `VercelBootstrap`, which means it is running on Vercel.
    public static var isRunningOnVercel: Bool {
        // Checked without connecting: connecting makes the bootstrap wait for this app on every
        // request.
        environmentValue(BootstrapProtocol.socketVariable).map { !$0.isEmpty } ?? false
    }

    static func scope(for headers: HTTPFields) -> RequestScope? {
        guard let name = HTTPField.Name(BootstrapProtocol.requestHeader),
            let token = headers[name], !token.isEmpty,
            let client = BootstrapClient.shared
        else { return nil }
        return client.scope(for: token)
    }

}

/// The request a task is handling: its headers and, under the bootstrap, its scope.
struct RequestContext: Sendable {
    let headers: HTTPFields
    let scope: RequestScope?
}

/// Milliseconds since the Unix epoch, truncated; 0 before it.
func unixMilliseconds(_ date: Date) -> UInt64 {
    let milliseconds = (date.timeIntervalSince1970 * 1000).rounded(.down)
    guard milliseconds.isFinite, milliseconds > 0 else { return 0 }
    return milliseconds < Double(UInt64.max) ? UInt64(milliseconds) : UInt64.max
}

/// Whole milliseconds in a duration; 0 for negative durations.
func milliseconds(_ duration: Duration) -> UInt64 {
    let (seconds, attoseconds) = duration.components
    guard seconds >= 0, attoseconds >= 0 else { return 0 }
    let (wholeSeconds, overflow) = UInt64(seconds).multipliedReportingOverflow(by: 1000)
    return overflow ? UInt64.max : wholeSeconds &+ UInt64(attoseconds / 1_000_000_000_000_000)
}

/// One request's `waitUntil` work. Releases the request back to the bootstrap exactly once, when
/// its response has finished and all work is done.
final class RequestScope: Sendable {
    let token: String
    let client: BootstrapClient

    private struct State {
        var responseFinished = false
        var released = false
        var cancelled = false
        var pending = 0
        var nextID = 0
        var tasks: [Int: Task<Void, Never>] = [:]
    }

    private let state = Mutex(State())
    /// The bootstrap's first answer about the request's hidden runtime cache configuration,
    /// empty included. `nil` until it answered.
    private let runtimeCache = Mutex<[String: String]?>(nil)

    init(token: String, client: BootstrapClient) {
        self.token = token
        self.client = client
    }

    /// The runtime cache configuration the bootstrap hid from this request's headers, asked once
    /// per request: later calls reuse the first answer. An answer cut short by cancelling the
    /// calling task is not kept.
    func runtimeCacheFields() async -> [String: String] {
        if let cached = runtimeCache.withLock({ $0 }) {
            return cached
        }
        // Concurrent first calls share one round trip in the client.
        let fields = await client.runtimeCacheFields(token: token)
        guard !Task.isCancelled else { return fields }
        return runtimeCache.withLock { cached in
            if let cached { return cached }
            cached = fields
            return fields
        }
    }

    func waitUntil(_ operation: @escaping @Sendable () async throws -> Void) {
        let id: Int? = state.withLock { state in
            guard !state.released else { return nil }
            state.pending += 1
            state.nextID += 1
            return state.nextID
        }
        guard let id else {
            // The request already finished; nothing will wait for this work.
            Task { await runReportingErrors(operation) }
            return
        }

        // Inherits the task-local scope, so logs from the work stay attributed to the request.
        let task = Task {
            await runReportingErrors(operation)
            self.taskFinished(id)
        }
        let cancelNow = state.withLock { state -> Bool in
            if state.pending > 0, !state.released {
                state.tasks[id] = task
            }
            return state.cancelled
        }
        if cancelNow {
            task.cancel()
        }
    }

    /// The bootstrap finished sending the response.
    func responseFinished() {
        let release = state.withLock { state -> Bool in
            state.responseFinished = true
            return Self.markReleasedIfDone(&state)
        }
        if release {
            client.released(self)
        }
    }

    /// Cancels outstanding `waitUntil` work so the request can end before the runtime times out.
    func cancelBackgroundWork() {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            state.cancelled = true
            return Array(state.tasks.values)
        }
        for task in tasks {
            task.cancel()
        }
    }

    private func taskFinished(_ id: Int) {
        let release = state.withLock { state -> Bool in
            state.tasks[id] = nil
            state.pending -= 1
            return Self.markReleasedIfDone(&state)
        }
        if release {
            client.released(self)
        }
    }

    private static func markReleasedIfDone(_ state: inout State) -> Bool {
        guard state.responseFinished, state.pending == 0, !state.released else { return false }
        state.released = true
        state.tasks = [:]
        return true
    }
}

private func runReportingErrors(_ operation: @Sendable () async throws -> Void) async {
    do {
        try await operation()
    } catch is CancellationError {
        // Expected when the request approaches its maximum duration.
    } catch {
        Logger(label: "vercel").error("waitUntil operation failed", metadata: ["error": "\(error)"])
    }
}
