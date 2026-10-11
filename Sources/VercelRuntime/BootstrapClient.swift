#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import NIOCore
import Synchronization
import VercelProtocol

/// The app's connection to `VercelBootstrap`, which runs it on Vercel.
///
/// Connected on first use of a request scope (``Vercel/withRequest(_:_:)`` or
/// ``Vercel/waitUntil(for:_:)``), so apps that never use one never connect and the bootstrap ends
/// their requests as soon as the response is done. Connecting waits for the bootstrap's `ready`,
/// so connecting lazily inside the first request is safe. Locally, or when the app runs outside the
/// bootstrap, there is no client and those APIs fall back to plain behavior.
final class BootstrapClient: Sendable {
    /// The process-wide client, connected on first access. `nil` outside the bootstrap.
    static let shared: BootstrapClient? = {
        guard let path = environmentValue(BootstrapProtocol.socketVariable), !path.isEmpty else { return nil }
        do {
            return try BootstrapClient(path: path)
        } catch {
            writeToStandardError("[vercel] failed to connect to the Vercel bootstrap: \(error)")
            return nil
        }
    }()

    private let connection = Mutex<IPCConnection?>(nil)
    private let scopes = Mutex<[String: RequestScope]>([:])
    private let runtimeCacheRequests = Mutex(RuntimeCacheRequests())
    /// Fetch metric ids increment per process, starting at 1.
    private let lastFetchMetricID = Atomic<UInt64>(0)

    /// How long ``runtimeCacheFields(token:timeout:)`` waits for the bootstrap by default. The
    /// bootstrap answers from memory, so this only matters if it is wedged.
    static let runtimeCacheTimeout: Duration = .seconds(1)

    /// Callers waiting for the bootstrap's `runtime-cache` answer, by request token and waiter id.
    ///
    /// Whoever removes a waiter (the answer, its timeout, its cancellation or the connection
    /// closing) resumes it, so each waiter is resumed exactly once.
    private struct RuntimeCacheRequests {
        struct Waiter {
            var continuation: CheckedContinuation<[String: String], Never>
            var timer: Task<Void, Never>?
        }

        var waiting: [String: [UInt64: Waiter]] = [:]
        var nextID: UInt64 = 0
        var closed = false

        mutating func remove(token: String, id: UInt64) -> Waiter? {
            guard let waiter = waiting[token]?.removeValue(forKey: id) else { return nil }
            if waiting[token]?.isEmpty == true {
                waiting[token] = nil
            }
            return waiter
        }
    }

    /// Connects and waits for the bootstrap's `ready`, so the bootstrap knows about this app
    /// before any request it is handling can finish.
    init(path: String) throws {
        let descriptor = try unixConnect(path: path)
        do {
            let frame = try readFrameBlocking(descriptor)
            guard BootstrapMessage(frame: frame) == .ready else {
                throw IPCConnection.Error.handshake("unexpected first message: \(String(decoding: frame, as: UTF8.self))")
            }
        } catch {
            _ = closeDescriptor(descriptor)
            throw error
        }
        // Held while connecting, so a frame handled right away waits for `connection` to be set.
        connection.withLock { connection in
            connection = IPCConnection(descriptor: descriptor) { [self] frame in
                self.receive(frame)
            } onClose: { [self] in
                self.connectionClosed()
            }
        }
    }

    /// The scope for a request token, created on first use.
    func scope(for token: String) -> RequestScope {
        scopes.withLock { scopes in
            if let scope = scopes[token] { return scope }
            let scope = RequestScope(token: token, client: self)
            scopes[token] = scope
            return scope
        }
    }

    func log(_ message: String, level: IPCMessage.LogLevel, token: String) {
        send(.log(token: token, message: message, level: level))
    }

    /// Reports an outbound HTTP request made for the request. The bootstrap drops it if the request
    /// already ended. Assigns the metric its id.
    func fetchMetric(_ metric: FetchMetric, token: String) {
        var metric = metric
        metric.id = lastFetchMetricID.add(1, ordering: .relaxed).newValue
        send(.fetchMetric(token: token, metric))
    }

    /// The runtime cache configuration the bootstrap hid from the request's headers
    /// (`x-vercel-sc-*`, keyed by lowercased name).
    ///
    /// Never fails: returns empty if there is none, the request already ended, the connection is
    /// closed, the answer could not be decoded, or no answer came within `timeout`. Cancelling
    /// the calling task also returns empty right away (rather than throwing `CancellationError`),
    /// like every other "no configuration" case; callers that cache the answer should check
    /// `Task.isCancelled`. Concurrent calls for the same request share one round trip.
    func runtimeCacheFields(token: String, timeout: Duration = runtimeCacheTimeout) async -> [String: String] {
        let id = runtimeCacheRequests.withLock { requests in
            requests.nextID += 1
            return requests.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let isFirst = runtimeCacheRequests.withLock { requests -> Bool? in
                    guard !requests.closed else { return nil }
                    let isFirst = requests.waiting[token]?.isEmpty ?? true
                    requests.waiting[token, default: [:]][id] = .init(continuation: continuation)
                    return isFirst
                }
                guard let isFirst else {
                    continuation.resume(returning: [:])
                    return
                }
                // The first caller asks; later ones share its answer. Asked even if this task was
                // just cancelled, because callers that joined meanwhile rely on it.
                if isFirst, !send(.runtimeCache(token: token)) {
                    runtimeCacheAnswered(token: token, headers: [:])
                    return
                }
                // Cancelled before the waiter was registered: the handler found nothing to resume.
                if Task.isCancelled {
                    finishRuntimeCacheWaiter(token: token, id: id)
                    return
                }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishRuntimeCacheWaiter(token: token, id: id)
                }
                let attached = runtimeCacheRequests.withLock { requests -> Bool in
                    guard requests.waiting[token]?[id] != nil else { return false }
                    requests.waiting[token]?[id]?.timer = timer
                    return true
                }
                if !attached {
                    timer.cancel()  // Already answered.
                }
            }
        } onCancel: {
            finishRuntimeCacheWaiter(token: token, id: id)
        }
    }

    /// Callers currently waiting for a `runtime-cache` answer.
    var runtimeCacheWaiterCount: Int {
        runtimeCacheRequests.withLock { $0.waiting.values.reduce(0) { $0 + $1.count } }
    }

    /// Called by a scope once its response finished and its `waitUntil` work is done.
    func released(_ scope: RequestScope) {
        scopes.withLock { scopes in
            if scopes[scope.token] === scope {
                scopes[scope.token] = nil
            }
        }
        send(.release(token: scope.token))
    }

    var activeScopeCount: Int {
        scopes.withLock { $0.count }
    }

    func flush() async {
        await connection.withLock { $0 }?.flush()
    }

    func close() async {
        await connection.withLock { $0 }?.close()
    }

    @discardableResult
    private func send(_ message: AppMessage) -> Bool {
        connection.withLock { $0 }?.send(json: message.json, droppable: message.isDroppable) ?? false
    }

    private func runtimeCacheAnswered(token: String, headers: [String: String]) {
        let waiting = runtimeCacheRequests.withLock { $0.waiting.removeValue(forKey: token) } ?? [:]
        for waiter in waiting.values {
            waiter.timer?.cancel()
            waiter.continuation.resume(returning: headers)
        }
    }

    /// Stops one caller waiting (timed out or cancelled), with no configuration.
    private func finishRuntimeCacheWaiter(token: String, id: UInt64) {
        guard let waiter = runtimeCacheRequests.withLock({ $0.remove(token: token, id: id) }) else { return }
        waiter.timer?.cancel()
        waiter.continuation.resume(returning: [:])
    }

    /// No answers will come anymore: release everyone waiting for one.
    private func connectionClosed() {
        let waiting = runtimeCacheRequests.withLock { requests in
            requests.closed = true
            defer { requests.waiting = [:] }
            return requests.waiting.values.flatMap(\.values)
        }
        for waiter in waiting {
            waiter.timer?.cancel()
            waiter.continuation.resume(returning: [:])
        }
    }

    private func receive(_ frame: ByteBuffer) {
        guard let message = BootstrapMessage(frame: frame.readableBytesView) else {
            // An answer we cannot read still answers its request: with no configuration.
            if let token = BootstrapMessage.undecodableRuntimeCacheToken(frame: frame.readableBytesView) {
                runtimeCacheAnswered(token: token, headers: [:])
            }
            return
        }
        switch message {
        case .ready:
            break
        case .responseFinished(let token):
            if let scope = scopes.withLock({ $0[token] }) {
                scope.responseFinished()
            } else {
                // Nothing in this process is tracking the request.
                send(.release(token: token))
            }
        case .approachingTimeout(let token):
            scopes.withLock { $0[token] }?.cancelBackgroundWork()
        case .runtimeCache(let token, let headers):
            runtimeCacheAnswered(token: token, headers: headers)
        }
    }
}

private func closeDescriptor(_ fd: CInt) -> CInt {
    close(fd)
}
