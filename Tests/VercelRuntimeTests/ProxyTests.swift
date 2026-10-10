#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Dispatch
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import VercelBootstrapCore
@testable import VercelRuntime

/// The proxy between a raw HTTP client (playing the functions runtime) and a real NIO server
/// (playing the app).
@Suite(.serialized) struct ProxyTests {
    let group = MultiThreadedEventLoopGroup.singleton

    final class Harness: Sendable {
        let app: any Channel
        let proxy: any Channel
        let recorder: Recorder

        init(app: any Channel, proxy: any Channel, recorder: Recorder) {
            self.app = app
            self.proxy = proxy
            self.recorder = recorder
        }

        var port: Int { proxy.localAddress!.port! }

        func close() async throws {
            try await proxy.close()
            try await app.close()
        }
    }

    func start(cronSecret: String? = nil, upstreamPort: Int? = nil) async throws -> Harness {
        let app = try await TestApp.bind(group: group)
        let recorder = Recorder()
        let tracker = RequestTracker { recorder.runtime($0) }
        let upstream = try SocketAddress(ipAddress: "127.0.0.1", port: upstreamPort ?? app.localAddress!.port!)
        let proxy = try await ProxyServer.bind(
            configuration: ProxyConfiguration(
                upstream: upstream,
                tracker: tracker,
                configuration: BootstrapConfiguration(executable: "App", cronPaths: ["/cron"]),
                cronSecret: cronSecret
            ),
            group: group
        )
        return Harness(app: app, proxy: proxy, recorder: recorder)
    }

    func internalHeaders(_ requestID: Int) -> String {
        "x-vercel-internal-invocation-id: inv\r\nx-vercel-internal-request-id: \(requestID)\r\nx-vercel-internal-trace-id: t\r\n"
    }

    func ends(_ harness: Harness) -> [UInt32?] {
        harness.recorder.toRuntime.compactMap { message in
            if case .end(let context, _) = message { context.requestID } else { nil }
        }
    }

    @Test func answersPingWithoutTheApp() async throws {
        let harness = try await start()
        let response = try await RawClient.exchange(port: harness.port, "GET /_vercel/ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.hasSuffix("\r\n\r\nOK"))
        #expect(harness.recorder.toRuntime.isEmpty)
        try await harness.close()
    }

    @Test func stripsInternalHeadersAndEndsTheRequest() async throws {
        let harness = try await start()
        let response = try await RawClient.exchange(
            port: harness.port,
            "GET /headers HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\(internalHeaders(1))x-vercel-internal-oidc-token: oidc\r\nx-vercel-bootstrap-request: spoofed\r\n\r\n"
        )
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        let body = try #require(response.split(separator: "\r\n\r\n", maxSplits: 1).last)
        #expect(body == "Host,Connection,x-vercel-oidc-token,x-vercel-bootstrap-request=1")
        try await waitUntil { ends(harness) == [1] }
        try await harness.close()
    }

    @Test func streamsChunkedResponses() async throws {
        let harness = try await start()
        let response = try await RawClient.exchange(port: harness.port, "GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\(internalHeaders(2))\r\n")
        #expect(response.contains("transfer-encoding: chunked"))
        #expect(response.hasSuffix("7\r\nchunk 1\r\n7\r\nchunk 2\r\n7\r\nchunk 3\r\n0\r\n\r\n"))
        try await waitUntil { ends(harness) == [2] }
        try await harness.close()
    }

    @Test func keepAliveCarriesSeveralRequests() async throws {
        let harness = try await start()
        let client = try RawClient(port: harness.port)
        for requestID in 1...3 {
            client.write("GET /hello HTTP/1.1\r\nHost: x\r\n\(internalHeaders(requestID))\r\n")
            let response = try await client.read(until: "hello")
            #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        }
        try await waitUntil { ends(harness) == [1, 2, 3] }
        client.close()
        try await harness.close()
    }

    @Test func forwardsRequestBodies() async throws {
        let harness = try await start()
        let body = String(repeating: "x", count: 200_000)
        let response = try await RawClient.exchange(
            port: harness.port,
            "POST /count HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\(internalHeaders(4))\r\n\(body)"
        )
        #expect(response.hasSuffix("\r\n\r\n200000"))
        try await waitUntil { ends(harness) == [4] }
        try await harness.close()
    }

    @Test func rejectsUnauthorizedCronRequests() async throws {
        let harness = try await start(cronSecret: "secret")
        let denied = try await RawClient.exchange(port: harness.port, "GET /cron HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\(internalHeaders(1))\r\n")
        #expect(denied.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        #expect(denied.hasSuffix(#"{"error":"unauthorized"}"#))
        let allowed = try await RawClient.exchange(
            port: harness.port,
            "GET /cron HTTP/1.1\r\nHost: x\r\nConnection: close\r\nAuthorization: Bearer secret\r\n\(internalHeaders(2))\r\n"
        )
        #expect(allowed.hasPrefix("HTTP/1.1 200 OK\r\n"))
        // Spellings routers resolve to the same route.
        for target in ["//cron", "/cron//", "/%63ron"] {
            let bypass = try await RawClient.exchange(port: harness.port, "GET \(target) HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            #expect(bypass.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"), "\(target) was not checked")
        }
        try await waitUntil { Set(ends(harness)) == [1, 2] }
        try await harness.close()
    }

    @Test func answers502WhenTheAppIsDown() async throws {
        let harness = try await start(upstreamPort: try reserveFreePort())
        let response = try await RawClient.exchange(port: harness.port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\(internalHeaders(5))\r\n")
        #expect(response.hasPrefix("HTTP/1.1 502 Bad Gateway\r\n"))
        try await waitUntil { ends(harness) == [5] }
        try await harness.close()
    }

    @Test func tunnelsUpgradesAndEndsAtSwitchingProtocols() async throws {
        let harness = try await start()
        let client = try RawClient(port: harness.port)
        client.write("GET /echo HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: echo\r\n\(internalHeaders(6))\r\n")
        let head = try await client.read(until: "\r\n\r\n")
        #expect(head.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        // The request ends at the upgrade, while the connection stays open.
        try await waitUntil { ends(harness) == [6] }

        client.write("ping 1")
        #expect(try await client.read(until: "ping 1").hasSuffix("ping 1"))
        let large = String(repeating: "y", count: 300_000)
        client.write(large)
        #expect(try await client.read(count: large.utf8.count) == large)
        client.close()
        try await Task.sleep(for: .milliseconds(100))
        #expect(ends(harness) == [6])
        try await harness.close()
    }

    @Test func declinedUpgradeEndsOnceAndClosesTheConnection() async throws {
        let harness = try await start()
        let response = try await RawClient.exchange(
            port: harness.port,
            "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: unknown\r\n\(internalHeaders(7))\r\n"
        )
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        try await waitUntil { ends(harness) == [7] }
        try await harness.close()
    }

    #if os(Linux)
    @Test func discoversItsOwnListeningSocket() async throws {
        let server = try await TestApp.bind(group: group)
        let port = try #require(server.localAddress?.port)
        let listeners = try #require(PortDiscovery.listeners(pid: getpid()))
        #expect(listeners.contains(PortDiscovery.Listener(host: "127.0.0.1", port: port)))
        try await server.close()
    }
    #endif
}

// MARK: - The app

/// A small HTTP server with the routes the tests use, and an `echo` upgrade.
enum TestApp {
    static func bind(group: any EventLoopGroup) async throws -> any Channel {
        try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withServerUpgrade: (upgraders: [EchoUpgrader()], completionHandler: { _ in })
                    )
                    try channel.pipeline.syncOperations.addHandler(Routes())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    final class Routes: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private var head: HTTPRequestHead?
        private var bodyBytes = 0

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                self.head = head
                bodyBytes = 0
            case .body(let body):
                bodyBytes += body.readableBytes
            case .end:
                guard let head else { return }
                respond(to: head, context: context)
            }
        }

        private func respond(to head: HTTPRequestHead, context: ChannelHandlerContext) {
            switch head.uri {
            case "/headers":
                let names = head.headers.map { name, value in
                    name == "x-vercel-bootstrap-request" ? "\(name)=\(value)" : name
                }
                send(names.joined(separator: ","), context: context)
            case "/count":
                send(String(bodyBytes), context: context)
            case "/stream":
                var headers = HTTPHeaders()
                headers.add(name: "transfer-encoding", value: "chunked")
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
                for index in 1...3 {
                    context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "chunk \(index)")))), promise: nil)
                }
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            default:
                send("hello", context: context)
            }
        }

        private func send(_ body: String, context: ChannelHandlerContext) {
            var headers = HTTPHeaders()
            headers.add(name: "content-length", value: String(body.utf8.count))
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: body)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    struct EchoUpgrader: HTTPServerProtocolUpgrader, Sendable {
        let supportedProtocol = "echo"
        let requiredUpgradeHeaders: [String] = []

        func buildUpgradeResponse(channel: any Channel, upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) -> EventLoopFuture<HTTPHeaders> {
            channel.eventLoop.makeSucceededFuture(initialResponseHeaders)
        }

        func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
            context.eventLoop.makeCompletedFuture {
                if let routes = try? context.pipeline.syncOperations.handler(type: Routes.self) {
                    _ = context.pipeline.syncOperations.removeHandler(routes)
                }
                try context.pipeline.syncOperations.addHandler(Echo())
            }
        }
    }

    final class Echo: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.write(data, promise: nil)
        }

        func channelReadComplete(context: ChannelHandlerContext) {
            context.flush()
        }
    }
}

// MARK: - The client

/// A blocking TCP client. Reads run on a dispatch thread, never on Swift's cooperative pool.
final class RawClient: @unchecked Sendable {
    private let fd: Int32
    private var buffer: [UInt8] = []

    init(port: Int) throws {
        #if canImport(Glibc)
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(result == 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Sends a request with `Connection: close` and reads the whole response.
    static func exchange(port: Int, _ request: String) async throws -> String {
        let client = try RawClient(port: port)
        defer { client.close() }
        client.write(request)
        return try await client.readToEnd()
    }

    func write(_ string: String) {
        var bytes = Array(string.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { libcWrite(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { return }
            bytes = bytes.dropFirst(written)
        }
    }

    func read(until marker: String) async throws -> String {
        try await onThread {
            let target = Array(marker.utf8)
            while self.buffer.firstRange(of: target) == nil {
                guard try self.fill() else { throw TestSocket.Timeout() }
            }
            let end = self.buffer.firstRange(of: target)!.upperBound
            defer { self.buffer.removeSubrange(..<end) }
            return String(decoding: self.buffer[..<end], as: UTF8.self)
        }
    }

    func read(count: Int) async throws -> String {
        try await onThread {
            while self.buffer.count < count {
                guard try self.fill() else { throw TestSocket.Timeout() }
            }
            defer { self.buffer.removeSubrange(..<count) }
            return String(decoding: self.buffer[..<count], as: UTF8.self)
        }
    }

    func readToEnd() async throws -> String {
        try await onThread {
            while try self.fill() {}
            defer { self.buffer = [] }
            return String(decoding: self.buffer, as: UTF8.self)
        }
    }

    func close() {
        _ = libcClose(fd)
    }

    /// Reads more bytes; `false` at end of stream.
    private func fill() throws -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = chunk.withUnsafeMutableBytes { libcRead(fd, $0.baseAddress, $0.count) }
        if count < 0 { throw TestSocket.Timeout() }
        buffer += chunk[0..<count]
        return count > 0
    }

    private func onThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

// libc's read/write/close, without clashing with the methods above.
private func libcRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { read(fd, buffer, count) }
private func libcWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { write(fd, buffer, count) }
private func libcClose(_ fd: Int32) -> Int32 { close(fd) }
