#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import Logging
import Synchronization
import Testing
@testable import VercelProtocol
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
        Vercel.withScope(client.scope(for: "7")) {
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

        Vercel.withScope(client.scope(for: "7")) {
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
        Vercel.withScope(client.scope(for: "7")) {
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
        Vercel.withScope(client.scope(for: "7")) {
            logger.warning("request log", metadata: ["user": "42"])
        }
        socket.send(#"{"type":"response-finished","token":"7"}"#)

        #expect(try await socket.nextFrame() == #"{"type":"log","token":"7","level":"warn","message":"request log user=42"}"#)
        #expect(try await socket.nextFrame() == releaseFrame)
    }

    /// The README's way to add VercelLogHandler to an existing logging setup.
    @Test func combinesWithOtherBackends() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)
        let other = RecordingLogHandler()
        let logger = Logger(label: "test") { label in
            MultiplexLogHandler([VercelLogHandler(label: label), other])
        }

        Vercel.withScope(client.scope(for: "7")) {
            logger.error("both backends")
        }
        socket.send(#"{"type":"response-finished","token":"7"}"#)

        #expect(try await socket.nextFrame() == #"{"type":"log","token":"7","level":"error","message":"both backends"}"#)
        #expect(try await socket.nextFrame() == releaseFrame)
        #expect(other.messages == ["both backends"])
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

    @Test func reportFetchSendsAMetricForTheRequest() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)
        let start = Date(timeIntervalSince1970: 1_791_734_674.495)

        Vercel.withScope(client.scope(for: "7")) {
            Vercel.reportFetch(method: "GET", host: "example.com", path: "/v1/x", query: "?a=1", statusCode: 200, start: start, duration: .milliseconds(45))
            Vercel.reportFetch(method: "POST", host: "api.test", path: "", statusCode: 70_000, start: start, duration: .seconds(1))
        }

        #expect(
            try await socket.nextFrame()
                == #"{"type":"fetch-metric","token":"7","metric":{"pathname":"/v1/x","search":"a=1","start":1791734674495,"duration":45,"host":"example.com","statusCode":200,"method":"GET","id":1}}"#
        )
        // Ids increment; an empty path is `/`, no query is "", and the status is clamped to the wire type.
        #expect(
            try await socket.nextFrame()
                == #"{"type":"fetch-metric","token":"7","metric":{"pathname":"/","search":"","start":1791734674495,"duration":1000,"host":"api.test","statusCode":65535,"method":"POST","id":2}}"#
        )
    }

    @Test func reportFetchDefaultsTheStartToDurationBeforeNow() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)
        let before = unixMilliseconds(Date())
        Vercel.withScope(client.scope(for: "7")) {
            Vercel.reportFetch(method: "GET", host: "h", path: "/", statusCode: 204, duration: .milliseconds(500))
        }
        let after = unixMilliseconds(Date())
        let frame = try await socket.nextFrame()
        let metric = try #require(AppMessage(frame: Array(frame.utf8)))
        guard case .fetchMetric(_, let reported) = metric else {
            Issue.record("unexpected \(frame)")
            return
        }
        #expect((before - 500...after - 500).contains(reported.start))
    }

    @Test func reportFetchWithExplicitHeadersOutsideARequest() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)
        let start = Date(timeIntervalSince1970: 1_791_734_674.495)
        let token = HTTPField.Name(BootstrapProtocol.requestHeader)!

        // No scope and no token: nothing to report to (and the bootstrap is never asked for).
        #expect(Vercel.currentScope == nil)
        Vercel.reportFetch(
            method: "GET", host: "skipped", path: "/", query: nil, statusCode: 200, start: start,
            duration: .zero, headers: [.accept: "*/*"], bootstrap: { () -> BootstrapClient? in
                Issue.record("must not connect without a token")
                return client
            }()
        )
        // A token in explicit headers attributes the metric to that request.
        Vercel.reportFetch(
            method: "GET", host: "example.com", path: "/a", query: nil, statusCode: 200, start: start,
            duration: .milliseconds(5), headers: [token: "8"], bootstrap: client
        )
        #expect(
            try await socket.nextFrame()
                == #"{"type":"fetch-metric","token":"8","metric":{"pathname":"/a","search":"","start":1791734674495,"duration":5,"host":"example.com","statusCode":200,"method":"GET","id":1}}"#
        )

        // The current request wins over explicit headers.
        Vercel.withScope(client.scope(for: "7")) {
            Vercel.reportFetch(
                method: "GET", host: "example.com", path: "/b", query: nil, statusCode: 204, start: start,
                duration: .zero, headers: [token: "8"], bootstrap: client
            )
        }
        #expect(
            try await socket.nextFrame()
                == #"{"type":"fetch-metric","token":"7","metric":{"pathname":"/b","search":"","start":1791734674495,"duration":0,"host":"example.com","statusCode":204,"method":"GET","id":2}}"#
        )
        #expect(client.activeScopeCount == 1, "explicit headers must not create a scope")
    }

    @Test func packageReportFetchWithoutBootstrapDoesNothing() {
        // No VERCEL_BOOTSTRAP_SOCKET in tests: `BootstrapClient.shared` is nil.
        Vercel.reportFetch(
            method: "GET", host: "h", path: "/", statusCode: 200, duration: .zero,
            headers: [HTTPField.Name(BootstrapProtocol.requestHeader)!: "9"]
        )
    }

    @Test func runtimeCacheFieldsAskTheBootstrap() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)

        let answer = Task { await client.runtimeCacheFields(token: "7") }
        #expect(try await socket.nextFrame() == #"{"type":"runtime-cache","token":"7"}"#)
        socket.send(#"{"type":"runtime-cache","token":"7","headers":{"x-vercel-sc-host":"cache.internal"}}"#)
        #expect(await answer.value == ["x-vercel-sc-host": "cache.internal"])

        // Unknown requests get an empty answer.
        let unknown = Task { await client.runtimeCacheFields(token: "8") }
        #expect(try await socket.nextFrame() == #"{"type":"runtime-cache","token":"8"}"#)
        socket.send(#"{"type":"runtime-cache","token":"8","headers":{}}"#)
        #expect(await unknown.value == [:])
    }

    @Test func concurrentRuntimeCacheCallersShareOneRequest() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)

        let answers = Task {
            await withTaskGroup(of: [String: String].self) { group in
                for _ in 0..<10 {
                    group.addTask { await client.runtimeCacheFields(token: "7") }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
        }
        #expect(try await socket.nextFrame() == #"{"type":"runtime-cache","token":"7"}"#)
        // Every caller registers before the answer.
        try await waitUntil { client.runtimeCacheWaiterCount == 10 }
        socket.send(#"{"type":"runtime-cache","token":"7","headers":{"x-vercel-sc-host":"h"}}"#)
        let values = await answers.value
        #expect(values.count == 10)
        #expect(values.allSatisfy { $0 == ["x-vercel-sc-host": "h"] })
        #expect(client.runtimeCacheWaiterCount == 0)

        // Only one request went out; the next frame is a new one.
        let next = Task { await client.runtimeCacheFields(token: "9") }
        #expect(try await socket.nextFrame() == #"{"type":"runtime-cache","token":"9"}"#)
        socket.send(#"{"type":"runtime-cache","token":"9","headers":{}}"#)
        #expect(await next.value == [:])
    }

    @Test func runtimeCacheFieldsAreEmptyOnceTheBootstrapIsGone() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)

        let pending = Task { await client.runtimeCacheFields(token: "7") }
        #expect(try await socket.nextFrame() == #"{"type":"runtime-cache","token":"7"}"#)
        socket.closePeer()
        #expect(await pending.value == [:])
        // And later calls do not wait for an answer that cannot come.
        #expect(await client.runtimeCacheFields(token: "8") == [:])
    }

    @Test func runtimeCacheFieldsTimeOut() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)
        #expect(BootstrapClient.runtimeCacheTimeout == .seconds(1))

        let started = ContinuousClock.now
        let pending = Task { await client.runtimeCacheFields(token: "7", timeout: .milliseconds(100)) }
        #expect(try await socket.nextFrame() == #"{"type":"runtime-cache","token":"7"}"#)
        #expect(await pending.value == [:])
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(client.runtimeCacheWaiterCount == 0)

        // A late answer resumes nobody twice, and the next call asks again.
        let late = #"{"type":"runtime-cache","token":"7","headers":{"x-vercel-sc-host":"late"}}"#
        socket.send(late)
        let next = Task { await client.runtimeCacheFields(token: "7", timeout: .seconds(30)) }
        #expect(try await socket.nextFrame() == #"{"type":"runtime-cache","token":"7"}"#)
        socket.send(late)
        #expect(await next.value == ["x-vercel-sc-host": "late"])
    }

    @Test func cancellingARuntimeCacheCallReturnsEmptyAtOnce() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)
        let started = ContinuousClock.now

        let cancelled = Task { await client.runtimeCacheFields(token: "7", timeout: .seconds(30)) }
        let other = Task { await client.runtimeCacheFields(token: "7", timeout: .seconds(30)) }
        #expect(try await socket.nextFrame() == #"{"type":"runtime-cache","token":"7"}"#)
        try await waitUntil { client.runtimeCacheWaiterCount == 2 }
        cancelled.cancel()
        #expect(await cancelled.value == [:])
        #expect(client.runtimeCacheWaiterCount == 1)

        // The other caller still gets the shared answer.
        socket.send(#"{"type":"runtime-cache","token":"7","headers":{"x-vercel-sc-host":"h"}}"#)
        #expect(await other.value == ["x-vercel-sc-host": "h"])

        // Already cancelled when calling: still asks (for callers that may join), returns empty.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.runtimeCacheFields(token: "8", timeout: .seconds(30))
        }
        #expect(await early.value == [:])
        #expect(try await socket.nextFrame() == #"{"type":"runtime-cache","token":"8"}"#)
        #expect(client.runtimeCacheWaiterCount == 0)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func undecodableRuntimeCacheAnswerIsEmpty() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)

        let pending = Task { await client.runtimeCacheFields(token: "7", timeout: .seconds(30)) }
        let unrelated = Task { await client.runtimeCacheFields(token: "8", timeout: .seconds(30)) }
        #expect(try await socket.frames(2).sorted() == [#"{"type":"runtime-cache","token":"7"}"#, #"{"type":"runtime-cache","token":"8"}"#])
        socket.send(#"{"type":"runtime-cache","token":"7","headers":{"x-vercel-sc-host":1}}"#)
        #expect(await pending.value == [:])
        // Only the request it names stopped waiting.
        #expect(client.runtimeCacheWaiterCount == 1)
        socket.send(#"{"type":"runtime-cache","token":"8","headers":{"x-vercel-sc-host":"h"}}"#)
        #expect(await unrelated.value == ["x-vercel-sc-host": "h"])
    }

    @Test func findsTheTokenOfUndecodableRuntimeCacheAnswers() {
        func token(_ json: String) -> String? {
            BootstrapMessage.undecodableRuntimeCacheToken(frame: Array(json.utf8))
        }
        #expect(token(#"{"type":"runtime-cache","token":"1","headers":{"a":1}}"#) == "1")
        #expect(token(#"{"type":"runtime-cache","token":"1"}"#) == "1")
        #expect(token(#"{"type":"runtime-cache","token":"1","headers":{"a":"b"}}"#) == nil, "decodable")
        #expect(token(#"{"type":"runtime-cache","headers":{}}"#) == nil)
        #expect(token(#"{"type":"response-finished","token":"1","x":{}}"#) == nil)
        #expect(token(#"{"type":"surprise","token":"1"}"#) == nil)
        #expect(token("not json") == nil)
    }

    @Test func theRequestScopeAsksTheBootstrapOnce() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)
        func resolve(token: String) async -> RuntimeCacheConfiguration? {
            let headers = HTTPFields([("x-vercel-bootstrap-request", token)])
            return await Vercel.$currentContext.withValue(RequestContext(headers: headers, scope: client.scope(for: token))) {
                await RuntimeCacheConfiguration.resolve()
            }
        }
        let expected = RuntimeCacheConfiguration(host: "cache.internal", headers: ["authorization": "Bearer abc"])

        let first = Task { await resolve(token: "7") }
        #expect(try await socket.nextFrame() == #"{"type":"runtime-cache","token":"7"}"#)
        socket.send(#"{"type":"runtime-cache","token":"7","headers":{"x-vercel-sc-headers":"{\"authorization\":\"Bearer abc\"}","x-vercel-sc-host":"cache.internal"}}"#)
        #expect(await first.value == expected)
        // Answered from the scope: no new request goes out (the next frame is for token 8).
        #expect(await resolve(token: "7") == expected)
        #expect(await resolve(token: "7") == expected)

        // An empty answer is remembered too.
        let empty = Task { await resolve(token: "8") }
        #expect(try await socket.nextFrame() == #"{"type":"runtime-cache","token":"8"}"#)
        socket.send(#"{"type":"runtime-cache","token":"8","headers":{}}"#)
        #expect(await empty.value == nil)
        #expect(await resolve(token: "8") == nil)

        // An answer cut short by cancellation is not: the next call asks again.
        let cancelled = Task { await resolve(token: "9") }
        #expect(try await socket.nextFrame() == #"{"type":"runtime-cache","token":"9"}"#)
        try await waitUntil { client.runtimeCacheWaiterCount == 1 }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        let retried = Task { await resolve(token: "9") }
        #expect(try await socket.nextFrame() == #"{"type":"runtime-cache","token":"9"}"#)
        socket.send(#"{"type":"runtime-cache","token":"9","headers":{"x-vercel-sc-headers":"{}","x-vercel-sc-host":"h"}}"#)
        #expect(await retried.value?.host == "h")
    }

    @Test func nestedWithRequestWithoutATokenKeepsTheOuterScope() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)
        let scope = client.scope(for: "7")
        let outer = HTTPFields([("x-vercel-bootstrap-request", "7"), ("x-vercel-id", "outer")])

        await Vercel.$currentContext.withValue(RequestContext(headers: outer, scope: scope)) {
            await Vercel.withRequest(HTTPFields([("x-vercel-id", "inner")])) {
                #expect(Vercel.currentScope === scope)
                #expect(Vercel.currentRequest?.id == "inner")
                // The hidden runtime cache configuration still comes from the outer request.
                let resolved = Task { await RuntimeCacheConfiguration.fields() }
                let frame = try? await socket.nextFrame()
                #expect(frame == #"{"type":"runtime-cache","token":"7"}"#)
                socket.send(#"{"type":"runtime-cache","token":"7","headers":{"x-vercel-sc-host":"h"}}"#)
                #expect(await resolved.value == ["x-vercel-sc-host": "h"])
            }
            #expect(Vercel.currentRequest?.id == "outer")
        }
    }

    @Test func resolvesHiddenRuntimeCacheConfigurationFromTheBootstrap() async throws {
        let socket = try TestSocket()
        let client = try await connect(socket)
        // What the app sees when the bootstrap hid the x-vercel-sc-* headers.
        let headers = HTTPFields([("x-vercel-bootstrap-request", "7"), ("accept", "*/*")])

        let resolved = Task {
            await Vercel.$currentContext.withValue(RequestContext(headers: headers, scope: client.scope(for: "7"))) {
                await RuntimeCacheConfiguration.resolve()
            }
        }
        #expect(try await socket.nextFrame() == #"{"type":"runtime-cache","token":"7"}"#)
        socket.send(#"{"type":"runtime-cache","token":"7","headers":{"x-vercel-sc-headers":"{\"authorization\":\"Bearer abc\"}","x-vercel-sc-host":"cache.internal"}}"#)
        #expect(await resolved.value == RuntimeCacheConfiguration(host: "cache.internal", headers: ["authorization": "Bearer abc"]))
    }

    @Test func protocolMessagesRoundTrip() {
        let metric = FetchMetric(id: 3, method: "GET", host: "h", pathname: "/p", search: "q=\"1\"", statusCode: 404, start: 1, duration: 2)
        let messages: [AppMessage] = [
            .log(token: "1", message: "line \"quoted\"\nnext", level: .error),
            .release(token: "2"),
            .fetchMetric(token: "3", metric),
            .runtimeCache(token: "4"),
        ]
        for message in messages {
            #expect(AppMessage(frame: Array(message.json.utf8)) == message)
        }
        let bootstrapMessages: [BootstrapMessage] = [
            .ready, .responseFinished(token: "3"), .approachingTimeout(token: "4"),
            .runtimeCache(token: "5", headers: [:]),
            .runtimeCache(token: "6", headers: ["x-vercel-sc-host": "h", "x-vercel-sc-headers": #"{"a":"b"}"#]),
        ]
        for message in bootstrapMessages {
            #expect(BootstrapMessage(frame: Array(message.json.utf8)) == message)
        }
        #expect(AppMessage(frame: Array(#"{"type":"log","token":"1","level":"loud","message":"x"}"#.utf8)) == nil)
        #expect(BootstrapMessage(frame: Array("not json".utf8)) == nil)
    }

    @Test func newProtocolMessagesHaveExactShapes() {
        let metric = FetchMetric(id: 1, method: "GET", host: "example.com", pathname: "/v1/x", search: "a=1", statusCode: 200, start: 1_791_734_674_495, duration: 45)
        #expect(
            AppMessage.fetchMetric(token: "1", metric).json
                == #"{"type":"fetch-metric","token":"1","metric":{"pathname":"/v1/x","search":"a=1","start":1791734674495,"duration":45,"host":"example.com","statusCode":200,"method":"GET","id":1}}"#
        )
        #expect(AppMessage.runtimeCache(token: "1").json == #"{"type":"runtime-cache","token":"1"}"#)
        #expect(
            BootstrapMessage.runtimeCache(token: "1", headers: ["x-vercel-sc-host": "h", "x-vercel-sc-basepath": "/b"]).json
                == #"{"type":"runtime-cache","token":"1","headers":{"x-vercel-sc-basepath":"/b","x-vercel-sc-host":"h"}}"#
        )
        #expect(BootstrapMessage.runtimeCache(token: "1", headers: [:]).json == #"{"type":"runtime-cache","token":"1","headers":{}}"#)
        #expect(AppMessage.fetchMetric(token: "1", metric).isDroppable)
        #expect(!AppMessage.runtimeCache(token: "1").isDroppable)
    }

    @Test func rejectsMalformedNewMessages() {
        // Wrongly typed or missing metric fields, and a runtime-cache answer without headers.
        #expect(AppMessage(frame: Array(#"{"type":"fetch-metric","token":"1"}"#.utf8)) == nil)
        #expect(
            AppMessage(frame: Array(#"{"type":"fetch-metric","token":"1","metric":{"pathname":"/","search":"","start":"1","duration":1,"host":"h","statusCode":200,"method":"GET","id":1}}"#.utf8)) == nil
        )
        #expect(AppMessage(frame: Array(#"{"type":"runtime-cache"}"#.utf8)) == nil)
        #expect(BootstrapMessage(frame: Array(#"{"type":"runtime-cache","token":"1"}"#.utf8)) == nil)
        #expect(BootstrapMessage(frame: Array(#"{"type":"runtime-cache","token":"1","headers":{"a":1}}"#.utf8)) == nil)
    }
}

/// Stands in for another swift-log backend, like a log service.
final class RecordingLogHandler: LogHandler, @unchecked Sendable {
    private let recorded = Mutex<[String]>([])
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        recorded.withLock { $0.append(event.message.description) }
    }

    var messages: [String] { recorded.withLock { $0 } }
}
