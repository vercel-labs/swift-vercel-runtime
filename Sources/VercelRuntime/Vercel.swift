import Logging
import Synchronization

/// Per-request Vercel features available from anywhere in a request handler.
public enum Vercel {
    @TaskLocal static var currentScope: RequestScope?

    /// The invocation the current task is handling, or `nil` outside a request or off Vercel.
    public static var currentInvocation: InvocationContext? {
        currentScope?.context
    }

    /// Keeps the function running until `operation` finishes, after the response is sent.
    ///
    /// Use it for work that should not delay the response, like analytics, cache warming or
    /// webhooks. On Vercel the request's `end` is only reported once every `waitUntil` operation
    /// has completed, so the instance is not frozen mid-work. Operations are cancelled when the
    /// request approaches its maximum duration, so check `Task.isCancelled` in long work.
    ///
    /// Outside a request, or when not running on Vercel, the operation simply runs in a new task.
    ///
    /// ```swift
    /// Vercel.waitUntil {
    ///     try await analytics.track("signup")
    /// }
    /// ```
    public static func waitUntil(_ operation: @escaping @Sendable () async throws -> Void) {
        if let scope = currentScope {
            scope.waitUntil(operation)
        } else {
            Task { await runReportingErrors(operation) }
        }
    }
}

/// The lifecycle of one request: its handler plus any `waitUntil` work. Sends `end` exactly once,
/// when both are done.
final class RequestScope: Sendable {
    let context: InvocationContext
    let runtime: VercelRuntime

    private struct State {
        var handlerFinished = false
        var ended = false
        var cancelled = false
        var pending = 0
        var nextID = 0
        var tasks: [Int: Task<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    init(context: InvocationContext, runtime: VercelRuntime) {
        self.context = context
        self.runtime = runtime
    }

    func waitUntil(_ operation: @escaping @Sendable () async throws -> Void) {
        let id: Int? = state.withLock { state in
            guard !state.ended else { return nil }
            state.pending += 1
            state.nextID += 1
            return state.nextID
        }
        guard let id else {
            // The request already ended; nothing will wait for this work.
            Task { await runReportingErrors(operation) }
            return
        }

        // Inherits the task-local scope, so logs from the work stay attributed to the request.
        let task = Task {
            await runReportingErrors(operation)
            self.taskFinished(id)
        }
        let cancelNow = state.withLock { state -> Bool in
            if state.pending > 0, !state.ended {
                state.tasks[id] = task
            }
            return state.cancelled
        }
        if cancelNow {
            task.cancel()
        }
    }

    func handlerFinished() {
        let shouldEnd = state.withLock { state -> Bool in
            state.handlerFinished = true
            return Self.markEndedIfDone(&state)
        }
        if shouldEnd {
            runtime.scopeEnded(self)
        }
    }

    /// Cancels outstanding `waitUntil` work so `end` can be sent before the runtime times out.
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
        let shouldEnd = state.withLock { state -> Bool in
            state.tasks[id] = nil
            state.pending -= 1
            return Self.markEndedIfDone(&state)
        }
        if shouldEnd {
            runtime.scopeEnded(self)
        }
    }

    private static func markEndedIfDone(_ state: inout State) -> Bool {
        guard state.handlerFinished, state.pending == 0, !state.ended else { return false }
        state.ended = true
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
