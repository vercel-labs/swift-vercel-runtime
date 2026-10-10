public import HTTPTypes
import Logging
import Synchronization

/// Optional Vercel features for request handlers.
///
/// Your server does not need any of this to run on Vercel: `VercelBootstrap` already answers
/// health checks, strips the runtime's internal headers and reports every request. Use these
/// APIs for the features that need to know which request your code is running for.
public enum Vercel {
    @TaskLocal static var currentScope: RequestScope?

    /// Runs `body` as part of the request with these headers.
    ///
    /// While `body` runs, ``VercelLogHandler`` attributes logs to the request in Vercel's logs and
    /// ``waitUntil(_:)`` keeps the function alive for background work. Call it from a middleware
    /// to cover every route:
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
    /// Locally, or for requests that did not come through Vercel, it just runs `body`.
    public static func withRequest<T>(_ headers: HTTPFields, _ body: () async throws -> T) async rethrows -> T {
        guard let scope = scope(for: headers) else {
            return try await body()
        }
        return try await $currentScope.withValue(scope) {
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
        $currentScope.withValue(scope) {
            scope.waitUntil(operation)
        }
    }

    /// Whether the app is connected to `VercelBootstrap`, which means it is running on Vercel.
    public static var isRunningOnVercel: Bool {
        BootstrapClient.shared != nil
    }

    private static func scope(for headers: HTTPFields) -> RequestScope? {
        guard let name = HTTPField.Name(BootstrapProtocol.requestHeader),
            let token = headers[name], !token.isEmpty,
            let client = BootstrapClient.shared
        else { return nil }
        return client.scope(for: token)
    }
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

    init(token: String, client: BootstrapClient) {
        self.token = token
        self.client = client
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
