import NIOCore
import Synchronization

/// Multi-producer, single-consumer queue of encoded IPC frames.
///
/// Producers (request handlers, the log handler, lifecycle hooks) append synchronously and never
/// touch the socket, so they never block on I/O. A single writer task takes everything pending as
/// one buffer and writes it with one flush: frames keep their enqueue order, which keeps a
/// request's logs ahead of its `end`, and bursts coalesce into a single syscall.
///
/// This is a `Mutex` rather than an actor on purpose: enqueueing must be synchronous (swift-log
/// handlers cannot `await`), and an uncontended lock is far cheaper than an actor hop.
final class IPCOutbox: Sendable {
    struct Batch: Sendable {
        var bytes: ByteBuffer
        /// Log messages dropped since the previous batch because the runtime was not reading.
        var droppedLogs: Int
    }

    private struct State {
        var pending = ByteBuffer()
        var pendingLogBytes = 0
        var droppedLogs = 0
        var totalDroppedLogs = 0
        /// Waiting for the bytes currently in `pending` to be written.
        var pendingFlushes: [CheckedContinuation<Void, Never>] = []
        /// Waiting for the batch the writer is currently writing.
        var inFlightFlushes: [CheckedContinuation<Void, Never>] = []
        var isWriting = false
        var writer: CheckedContinuation<Batch?, Never>?
        /// No new frames are accepted; the writer drains what is pending, then stops.
        var isFinished = false
        /// The connection is gone; pending frames are discarded.
        var isTerminated = false
    }

    /// Upper bound on log bytes waiting to be written. Control messages (`server-started`, `end`,
    /// `unrecoverable-error`) are never dropped.
    let maxPendingLogBytes: Int
    private let state = Mutex(State())

    init(maxPendingLogBytes: Int = 1 << 20) {
        self.maxPendingLogBytes = maxPendingLogBytes
    }

    /// Appends one message. Never blocks on I/O. Returns `false` if the message was dropped.
    @discardableResult
    func enqueue(_ json: String, isLog: Bool) -> Bool {
        let frameSize = json.utf8.count + 1
        let (accepted, wakeUp) = state.withLock { state -> (Bool, (CheckedContinuation<Batch?, Never>, Batch)?) in
            guard !state.isFinished else { return (false, nil) }
            if isLog {
                guard state.pendingLogBytes + frameSize <= maxPendingLogBytes else {
                    state.droppedLogs += 1
                    state.totalDroppedLogs += 1
                    return (false, nil)
                }
                state.pendingLogBytes += frameSize
            }
            state.pending.writeString(json)
            state.pending.writeInteger(UInt8(0))
            guard let writer = state.writer else { return (true, nil) }
            state.writer = nil
            return (true, (writer, Self.takeBatch(&state)))
        }
        if let (writer, batch) = wakeUp {
            writer.resume(returning: batch)
        }
        return accepted
    }

    /// The writer's next batch: everything pending, waiting if there is nothing yet. Returns `nil`
    /// once the outbox is finished and drained, or terminated.
    func nextBatch() async -> Batch? {
        await withCheckedContinuation { continuation in
            let immediate: Batch?? = state.withLock { state in
                if state.isTerminated { return .some(nil) }
                if state.pending.readableBytes > 0 { return .some(Self.takeBatch(&state)) }
                if state.isFinished { return .some(nil) }
                precondition(state.writer == nil, "IPCOutbox supports a single writer")
                state.writer = continuation
                return .none
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    /// Called by the writer once the last batch reached the socket.
    func batchWritten() {
        let flushes = state.withLock { state in
            state.isWriting = false
            defer { state.inFlightFlushes = [] }
            return state.inFlightFlushes
        }
        for flush in flushes {
            flush.resume()
        }
    }

    /// Waits until everything enqueued before this call has been written to the socket, or the
    /// connection is gone.
    func flush() async {
        await withCheckedContinuation { continuation in
            let isFlushed = state.withLock { state in
                if state.isTerminated { return true }
                if state.pending.readableBytes > 0 {
                    state.pendingFlushes.append(continuation)
                    return false
                }
                if state.isWriting {
                    state.inFlightFlushes.append(continuation)
                    return false
                }
                return true
            }
            if isFlushed {
                continuation.resume()
            }
        }
    }

    /// Stops accepting messages. The writer drains what is pending, then stops.
    func finish() {
        let writer = state.withLock { state -> CheckedContinuation<Batch?, Never>? in
            state.isFinished = true
            guard state.pending.readableBytes == 0 else { return nil }
            defer { state.writer = nil }
            return state.writer
        }
        writer?.resume(returning: nil)
    }

    /// The connection is gone: drops pending frames and releases every waiter.
    func terminate() {
        let (writer, flushes) = state.withLock { state in
            state.isFinished = true
            state.isTerminated = true
            state.pending = ByteBuffer()
            state.pendingLogBytes = 0
            let flushes = state.pendingFlushes + state.inFlightFlushes
            state.pendingFlushes = []
            state.inFlightFlushes = []
            defer { state.writer = nil }
            return (state.writer, flushes)
        }
        writer?.resume(returning: nil)
        for flush in flushes {
            flush.resume()
        }
    }

    /// Log messages dropped over the life of the outbox.
    var totalDroppedLogs: Int {
        state.withLock { $0.totalDroppedLogs }
    }

    private static func takeBatch(_ state: inout State) -> Batch {
        let batch = Batch(bytes: state.pending, droppedLogs: state.droppedLogs)
        state.pending = ByteBuffer()
        state.pendingLogBytes = 0
        state.droppedLogs = 0
        state.inFlightFlushes = state.pendingFlushes
        state.pendingFlushes = []
        state.isWriting = true
        return batch
    }
}
