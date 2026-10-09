import NIOCore
import Synchronization
import Testing
@testable import VercelRuntime

@Suite struct IPCOutboxTests {
    func frames(_ batch: IPCOutbox.Batch?) -> [String] {
        guard let batch else { return [] }
        return batch.bytes.readableBytesView.split(separator: 0, omittingEmptySubsequences: false)
            .dropLast()
            .map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func batchesEverythingPendingInOrder() async {
        let outbox = IPCOutbox()
        outbox.enqueue("a", isLog: false)
        outbox.enqueue("b", isLog: true)
        outbox.enqueue("c", isLog: false)

        #expect(frames(await outbox.nextBatch()) == ["a", "b", "c"])
    }

    @Test func writerWakesUpOnEnqueue() async {
        let outbox = IPCOutbox()
        let next = Task { await outbox.nextBatch() }
        try? await Task.sleep(for: .milliseconds(20))
        outbox.enqueue("late", isLog: false)
        #expect(frames(await next.value) == ["late"])
    }

    @Test func dropsLogsOverTheCapButNeverControlMessages() async {
        let outbox = IPCOutbox(maxPendingLogBytes: 10)
        #expect(outbox.enqueue("1234", isLog: true))   // 5 bytes with NUL
        #expect(outbox.enqueue("1234", isLog: true))   // 10
        #expect(!outbox.enqueue("x", isLog: true))     // over the cap
        #expect(outbox.enqueue(String(repeating: "e", count: 100), isLog: false))

        let batch = await outbox.nextBatch()
        #expect(batch?.droppedLogs == 1)
        #expect(frames(batch).count == 3)
        #expect(outbox.totalDroppedLogs == 1)

        // The cap applies to pending bytes, so it resets once the writer takes them.
        #expect(outbox.enqueue("1234", isLog: true))
    }

    @Test func flushWaitsForTheInFlightBatch() async {
        let outbox = IPCOutbox()
        await outbox.flush()  // idle: returns immediately

        outbox.enqueue("a", isLog: false)
        let flushed = Mutex(false)
        let flush = Task {
            await outbox.flush()
            flushed.withLock { $0 = true }
        }
        _ = await outbox.nextBatch()  // taken, but not written yet
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!flushed.withLock { $0 })

        outbox.batchWritten()
        await flush.value
        #expect(flushed.withLock { $0 })
    }

    @Test func finishDrainsThenStops() async {
        let outbox = IPCOutbox()
        outbox.enqueue("a", isLog: false)
        outbox.finish()
        #expect(!outbox.enqueue("b", isLog: false))
        #expect(frames(await outbox.nextBatch()) == ["a"])
        outbox.batchWritten()
        #expect(await outbox.nextBatch() == nil)
    }

    @Test func terminateReleasesWaiters() async {
        let outbox = IPCOutbox()
        outbox.enqueue("a", isLog: false)
        let flush = Task { await outbox.flush() }
        try? await Task.sleep(for: .milliseconds(20))
        outbox.terminate()
        await flush.value
        #expect(await outbox.nextBatch() == nil)
    }
}

extension IPCOutbox.Batch: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bytes == rhs.bytes && lhs.droppedLogs == rhs.droppedLogs
    }
}
