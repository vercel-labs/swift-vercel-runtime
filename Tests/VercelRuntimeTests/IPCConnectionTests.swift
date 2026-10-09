import Foundation
import Synchronization
import Testing
@testable import VercelRuntime

/// The NIO-backed connection against a fake functions runtime on a real Unix socket.
@Suite(.serialized) struct IPCConnectionTests {
    @Test func sendsNulTerminatedFramesInOrder() async throws {
        let socket = try TestSocket()
        let runtime = VercelRuntime(ipcPath: socket.path)
        try socket.accept()

        runtime.serverStarted(httpPort: 3000)
        runtime.requestEnded(InvocationContext(invocationID: "inv-1", requestID: 1))

        let frames = try await socket.frames(2)
        #expect(frames[0].hasPrefix(#"{"type":"server-started","payload":{"initDuration":"#))
        #expect(frames[0].hasSuffix(#","httpPort":3000}}"#))
        #expect(frames[1] == #"{"type":"end","payload":{"context":{"invocationId":"inv-1","requestId":1},"error":null}}"#)
    }

    @Test func disabledWithoutIPCPath() {
        #expect(!VercelRuntime(ipcPath: nil).isEnabled)
        #expect(!VercelRuntime(ipcPath: "").isEnabled)
        // A missing socket fails synchronously, logs, and disables instead of crashing.
        #expect(!VercelRuntime(ipcPath: "/tmp/does-not-exist-\(getpid()).sock").isEnabled)
    }

    @Test func rejectsOverlongPath() {
        let path = "/tmp/" + String(repeating: "x", count: 200)
        #expect(throws: IPCConnection.Error.pathTooLong(path)) {
            try IPCConnection(path: path)
        }
    }

    @Test func flushReturnsOnceBytesAreOnTheSocket() async throws {
        let socket = try TestSocket()
        let runtime = VercelRuntime(ipcPath: socket.path)
        try socket.accept()

        runtime.serverStarted(httpPort: 1234)
        await runtime.flush()

        // Already written: readable without waiting.
        socket.setReadTimeout(milliseconds: 100)
        #expect(try await socket.nextFrame().contains(#""httpPort":1234"#))
    }

    @Test func unrecoverableErrorIsWrittenBeforeReturning() async throws {
        let socket = try TestSocket()
        let runtime = VercelRuntime(ipcPath: socket.path)
        try socket.accept()

        await runtime.unrecoverableError(message: "boom")

        socket.setReadTimeout(milliseconds: 100)
        #expect(try await socket.nextFrame() == #"{"type":"unrecoverable-error","payload":{"exitCode":1,"message":"boom"}}"#)
    }

    @Test func shutdownDrainsQueueThenClosesSocket() async throws {
        let socket = try TestSocket()
        let runtime = VercelRuntime(ipcPath: socket.path)
        try socket.accept()

        for requestID in 1...3 {
            runtime.requestEnded(InvocationContext(invocationID: "inv", requestID: UInt32(requestID)))
        }
        await runtime.shutdown()

        #expect(try await socket.frames(3).count == 3)
        #expect(try await socket.isClosed())
        #expect(runtime.connection?.send(.serverStarted(initDuration: 0, httpPort: 1)) == false)
    }

    @Test func decodesFramesSplitAcrossReads() async throws {
        let socket = try TestSocket()
        let received = Mutex<[RuntimeMessage]>([])
        let connection = try IPCConnection(path: socket.path) { message in
            received.withLock { $0.append(message) }
        }
        try socket.accept()

        let frame = Array(#"{"type":"approaching-timeout","context":{"invocationId":"inv","requestId":9}}"#.utf8) + [0]
        socket.sendRaw(Array(frame[..<20]))
        try await Task.sleep(for: .milliseconds(50))
        socket.sendRaw(Array(frame[20...]) + Array(#"{"type":"future-message"}"#.utf8) + [0])

        try await waitUntil { received.withLock { $0.count == 2 } }
        #expect(received.withLock { $0 } == [
            .approachingTimeout(InvocationContext(invocationID: "inv", requestID: 9)),
            .unknown(type: "future-message"),
        ])
        await connection.close()
    }

    /// Many concurrent requests, each logging then ending: every request's logs must arrive
    /// before its `end`, with nothing lost or duplicated.
    @Test func preservesPerRequestOrderingUnderConcurrency() async throws {
        let socket = try TestSocket()
        let runtime = VercelRuntime(ipcPath: socket.path)
        try socket.accept()
        let requests = 200
        let logsPerRequest = 20

        let readAll = Task { try await socket.frames(requests * (logsPerRequest + 1)) }
        await withTaskGroup { group in
            for requestID in 0..<requests {
                group.addTask {
                    let context = InvocationContext(invocationID: "inv", requestID: UInt32(requestID))
                    for line in 0..<logsPerRequest {
                        runtime.log("line \(line)", level: .info, context: context)
                    }
                    runtime.requestEnded(context)
                }
            }
        }
        let frames = try await readAll.value

        var logs: [UInt32: Int] = [:]
        var ended: Set<UInt32> = []
        for frame in frames {
            let object = try #require(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
            let payload = try #require(object["payload"] as? [String: Any])
            let context = try #require(payload["context"] as? [String: Any])
            let requestID = try #require((context["requestId"] as? NSNumber)?.uint32Value)
            switch object["type"] as? String {
            case "log":
                #expect(!ended.contains(requestID), "log after end for request \(requestID)")
                logs[requestID, default: 0] += 1
            case "end":
                #expect(logs[requestID] == logsPerRequest, "end before all logs for request \(requestID)")
                #expect(ended.insert(requestID).inserted, "duplicate end for request \(requestID)")
            default:
                Issue.record("unexpected frame \(frame)")
            }
        }
        #expect(ended.count == requests)
        #expect(runtime.connection?.droppedLogCount == 0)
    }

    /// A runtime that stops reading must not block callers. Logs beyond the cap are dropped and
    /// counted; `end` is never dropped.
    @Test func stalledRuntimeNeverBlocksSendersAndNeverDropsEnd() async throws {
        let socket = try TestSocket()
        let runtime = VercelRuntime(ipcPath: socket.path)
        try socket.accept()
        let context = InvocationContext(invocationID: "inv", requestID: 1)
        let line = String(repeating: "x", count: 2048)

        // ~10 MB of logs while nobody reads: far more than the socket buffer and the 1 MiB cap.
        let started = ContinuousClock.now
        for _ in 0..<5000 {
            runtime.log(line, level: .info, context: context)
        }
        runtime.requestEnded(context)
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(1), "sending blocked for \(elapsed)")

        // Start reading: everything accepted arrives, ending with `end`.
        let frames = try await socket.frames { $0.contains(#""type":"end""#) }
        let dropped = try #require(runtime.connection?.droppedLogCount)
        #expect(dropped > 0)
        #expect(frames.count - 1 + dropped == 5000)
        print("stalled runtime: sent 5000 x 2 KB logs in \(elapsed); delivered \(frames.count - 1), dropped \(dropped)")
    }

    @Test func throughput() async throws {
        let socket = try TestSocket()
        let runtime = VercelRuntime(ipcPath: socket.path)
        try socket.accept()
        let senders = 8
        let messagesPerSender = 25_000
        let context = InvocationContext(invocationID: "inv", requestID: 1)

        let readAll = Task { try await socket.frames(senders * messagesPerSender).count }
        let started = ContinuousClock.now
        await withTaskGroup { group in
            for _ in 0..<senders {
                group.addTask {
                    for _ in 0..<messagesPerSender {
                        runtime.requestEnded(context)
                    }
                }
            }
        }
        let enqueued = ContinuousClock.now - started
        #expect(try await readAll.value == senders * messagesPerSender)
        let delivered = ContinuousClock.now - started
        print("throughput: \(senders * messagesPerSender) messages enqueued in \(enqueued), delivered in \(delivered)")
    }
}

func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TestSocket.Timeout() }
        try await Task.sleep(for: .milliseconds(5))
    }
}
