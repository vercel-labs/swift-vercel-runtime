import HTTPTypes
import Logging
import Synchronization
import Testing
@testable import VercelRuntime

/// The app side of the bootstrap protocol, against a fake bootstrap on a real Unix socket.
@Suite(.serialized) struct AppLifecycleTests {
    let releaseFrame = #"{"type":"release","token":"7"}"#

    /// Connects a client the way an app does: it waits for the bootstrap's `ready`.
    func connect(_ socket: TestSocket) async throws -> BootstrapClient {
        let path = socket.path
        let client = Task.detached { try BootstrapClient(path: path) }
        try socket.accept()
        socket.send(#"{"type":"ready"}"#)
        return try await client.value
    }

    @Test func connectingRequiresReady() async throws {
        let socket = try TestSocket()
        let path = socket.path
        let client = Task.detached { try BootstrapClient(path: path) }
        try socket.accept()
        socket.send(#"{"type":"response-finished","token":"1"}"#)
        await #expect(throws: IPCConnection.Error.self) {
            try await client.value
        }
    }

    @Test func untrackedRequestIsReleasedImmediately() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)
        socket.send(#"{"type":"response-finished","token":"7"}"#)
        #expect(try await socket.nextFrame() == releaseFrame)
        #expect(client.activeScopeCount == 0)
    }

    @Test func waitUntilDelaysReleaseButNotTheResponse() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)
        let logger = Logger(label: "test") { VercelLogHandler(label: $0) }

        let started = ContinuousClock.now
        Vercel.$currentScope.withValue(client.scope(for: "7")) {
            Vercel.waitUntil {
                try await Task.sleep(for: .milliseconds(300))
                logger.info("background done")
            }
        }
        #expect(ContinuousClock.now - started < .milliseconds(100), "the handler must not wait")
        socket.send(#"{"type":"response-finished","token":"7"}"#)

        // The background log is attributed to the request and arrives before the release.
        #expect(try await socket.nextFrame() == #"{"type":"log","token":"7","level":"info","message":"background done"}"#)
        #expect(try await socket.nextFrame() == releaseFrame)
        #expect(ContinuousClock.now - started >= .milliseconds(300))
        #expect(client.activeScopeCount == 0)
    }

    @Test func workFinishedBeforeTheResponseReleasesOnResponseFinished() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)
        let done = Mutex(false)

        Vercel.$currentScope.withValue(client.scope(for: "7")) {
            Vercel.waitUntil { done.withLock { $0 = true } }
        }
        try await waitUntil { done.withLock { $0 } }
        socket.send(#"{"type":"response-finished","token":"7"}"#)
        #expect(try await socket.nextFrame() == releaseFrame)
    }

    @Test func approachingTimeoutCancelsWaitUntilWork() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)
        let cancelled = Mutex(false)

        let started = ContinuousClock.now
        Vercel.$currentScope.withValue(client.scope(for: "7")) {
            Vercel.waitUntil {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.withLock { $0 = true }
                    throw error
                }
            }
        }
        socket.send(#"{"type":"response-finished","token":"7"}"#)
        socket.send(#"{"type":"approaching-timeout","token":"7"}"#)

        #expect(try await socket.nextFrame() == releaseFrame)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(cancelled.withLock { $0 })
    }

    @Test func logsOutsideARequestGoToStandardOutput() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)
        let logger = Logger(label: "test") { VercelLogHandler(label: $0) }

        logger.info("startup log goes to stdout")
        Vercel.$currentScope.withValue(client.scope(for: "7")) {
            logger.warning("request log", metadata: ["user": "42"])
        }
        socket.send(#"{"type":"response-finished","token":"7"}"#)

        #expect(try await socket.nextFrame() == #"{"type":"log","token":"7","level":"warn","message":"request log user=42"}"#)
        #expect(try await socket.nextFrame() == releaseFrame)
    }

    @Test func withoutTheBootstrapEverythingRunsPlainly() async throws {
        // No VERCEL_BOOTSTRAP_SOCKET in the test environment.
        #expect(!Vercel.isRunningOnVercel)
        let headers: HTTPFields = [HTTPField.Name("x-vercel-bootstrap-request")!: "7"]
        let ran = Mutex(false)
        await withCheckedContinuation { continuation in
            Task {
                await Vercel.withRequest(headers) {
                    #expect(Vercel.currentScope == nil)
                    Vercel.waitUntil {
                        ran.withLock { $0 = true }
                        continuation.resume()
                    }
                }
            }
        }
        #expect(ran.withLock { $0 })
    }

    @Test func protocolMessagesRoundTrip() {
        let messages: [AppMessage] = [
            .log(token: "1", message: "line \"quoted\"\nnext", level: .error),
            .release(token: "2"),
        ]
        for message in messages {
            #expect(AppMessage(frame: Array(message.json.utf8)) == message)
        }
        let bootstrapMessages: [BootstrapMessage] = [.ready, .responseFinished(token: "3"), .approachingTimeout(token: "4")]
        for message in bootstrapMessages {
            #expect(BootstrapMessage(frame: Array(message.json.utf8)) == message)
        }
        #expect(AppMessage(frame: Array(#"{"type":"log","token":"1","level":"loud","message":"x"}"#.utf8)) == nil)
        #expect(BootstrapMessage(frame: Array("not json".utf8)) == nil)
    }
}
