import Logging
import Synchronization
import Testing
@testable import VercelRuntime

/// End-to-end request lifecycle against a fake functions runtime on a real Unix socket.
@Suite(.serialized) struct RequestLifecycleTests {
    let context = InvocationContext(invocationID: "inv-1", requestID: 7)
    let endFrame = #"{"type":"end","payload":{"context":{"invocationId":"inv-1","requestId":7},"error":null}}"#

    @Test func endIsSentAfterHandler() async throws {
        let socket = try TestSocket()
        let runtime = VercelRuntime(ipcPath: socket.path)
        try socket.accept()

        let result = await runtime.withRequest(context) {
            #expect(Vercel.currentInvocation == context)
            return 42
        }

        #expect(result == 42)
        #expect(try await socket.nextFrame() == endFrame)
        #expect(Vercel.currentInvocation == nil)
    }

    @Test func endIsSentWhenHandlerThrows() async throws {
        struct Failure: Error {}
        let socket = try TestSocket()
        let runtime = VercelRuntime(ipcPath: socket.path)
        try socket.accept()

        await #expect(throws: Failure.self) {
            try await runtime.withRequest(context) { throw Failure() }
        }
        #expect(try await socket.nextFrame() == endFrame)
    }

    @Test func waitUntilDelaysEndButNotTheResponse() async throws {
        let socket = try TestSocket()
        let runtime = VercelRuntime(ipcPath: socket.path)
        try socket.accept()
        let logger = Logger(label: "test") { VercelLogHandler(label: $0) }

        let started = ContinuousClock.now
        await runtime.withRequest(context) {
            Vercel.waitUntil {
                try await Task.sleep(for: .milliseconds(300))
                logger.info("background done")
            }
        }
        #expect(ContinuousClock.now - started < .milliseconds(100), "the handler must not wait")

        // The background log is attributed to the request and arrives before `end`.
        let log = try await socket.nextFrame()
        #expect(log.contains(#""type":"log""#))
        #expect(log.contains(#""context":{"invocationId":"inv-1","requestId":7}"#))
        #expect(log.contains(#""message":"YmFja2dyb3VuZCBkb25l""#))  // base64("background done")
        #expect(log.contains(#""level":"info""#))
        #expect(try await socket.nextFrame() == endFrame)
        #expect(ContinuousClock.now - started >= .milliseconds(300))
    }

    @Test func approachingTimeoutCancelsWaitUntilWork() async throws {
        let socket = try TestSocket()
        let runtime = VercelRuntime(ipcPath: socket.path)
        try socket.accept()
        let cancelled = Mutex(false)

        let started = ContinuousClock.now
        await runtime.withRequest(context) {
            Vercel.waitUntil {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.withLock { $0 = true }
                    throw error
                }
            }
        }
        socket.send(#"{"type":"approaching-timeout","context":{"invocationId":"inv-1","requestId":7}}"#)

        #expect(try await socket.nextFrame() == endFrame)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(cancelled.withLock { $0 })
    }

    @Test func logsOutsideARequestDoNotUseIPC() async throws {
        let socket = try TestSocket()
        let runtime = VercelRuntime(ipcPath: socket.path)
        try socket.accept()
        let logger = Logger(label: "test") { VercelLogHandler(label: $0) }

        logger.info("startup log goes to stdout")
        await runtime.withRequest(context) {
            logger.warning("request log", metadata: ["user": "42"])
        }

        let log = try await socket.nextFrame()
        #expect(log.contains(#""level":"warn""#))
        #expect(log.contains(#""message":"cmVxdWVzdCBsb2cgdXNlcj00Mg==""#))  // base64("request log user=42")
        #expect(try await socket.nextFrame() == endFrame)
    }

    @Test func disabledRuntimeRunsHandlersAndWaitUntil() async throws {
        let runtime = VercelRuntime(ipcPath: nil)
        let ran = Mutex(false)
        await withCheckedContinuation { continuation in
            Task {
                await runtime.withRequest(context) {
                    #expect(Vercel.currentInvocation == nil)
                    Vercel.waitUntil {
                        ran.withLock { $0 = true }
                        continuation.resume()
                    }
                }
            }
        }
        #expect(ran.withLock { $0 })
    }
}
