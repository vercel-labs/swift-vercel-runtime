import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import VercelHTTP

/// The real transport against a local HTTP server.
@Suite struct AsyncHTTPClientTransportTests {
    let client = VercelHTTPClient(transport: AsyncHTTPClientTransport(), reportFetch: { _ in })

    @Test func sendsRealRequests() async throws {
        let server = try await TestServer.start()
        defer { server.close() }

        let response = try await client.send(
            .put,
            "http://127.0.0.1:\(server.port)/echo?a=1&b=%20",
            headerFields: [HTTPField.Name("x-test")!: "hello", .contentType: "text/plain"],
            body: Array("request body".utf8)
        )

        #expect(response.status == .created)
        #expect(response.status.reasonPhrase == "Created")
        #expect(response.headerFields[HTTPField.Name("x-method")!] == "PUT")
        #expect(response.headerFields[HTTPField.Name("x-uri")!] == "/echo?a=1&b=%20")
        #expect(response.headerFields[HTTPField.Name("x-test")!] == "hello")
        #expect(response.headerFields[HTTPField.Name("x-host")!] == "127.0.0.1:\(server.port)")
        #expect(response.headerFields[values: .setCookie] == ["a=1", "b=2"])
        #expect(response.text == "request body")
    }

    @Test func requestsWithoutABody() async throws {
        let server = try await TestServer.start()
        defer { server.close() }
        let get = try await client.send(.get, "http://127.0.0.1:\(server.port)/echo")
        #expect(get.headerFields[HTTPField.Name("x-method")!] == "GET")
        #expect(get.body.isEmpty)
        let head = try await client.send(.head, "http://127.0.0.1:\(server.port)/echo")
        #expect(head.status == .created)
        #expect(head.body.isEmpty)
    }

    @Test func redirectsArePerRequest() async throws {
        let server = try await TestServer.start()
        defer { server.close() }
        let url = "http://127.0.0.1:\(server.port)/redirect"

        let followed = try await client.send(.get, url)
        #expect(followed.status == .created)
        #expect(followed.headerFields[HTTPField.Name("x-uri")!] == "/echo?redirected=1")

        let returned = try await client.send(.get, url, followRedirects: false)
        #expect(returned.status == .found)
        #expect(returned.headerFields[.location] == "/echo?redirected=1")
    }

    @Test func capsTheBodyWhileStreaming() async throws {
        let server = try await TestServer.start()
        defer { server.close() }
        let capped = VercelHTTPClient(transport: AsyncHTTPClientTransport(), maxResponseBodySize: 1000, reportFetch: { _ in })
        #expect(try await capped.send(.get, "http://127.0.0.1:\(server.port)/bytes/1000").body.count == 1000)
        await #expect {
            _ = try await capped.send(.get, "http://127.0.0.1:\(server.port)/bytes/1001")
        } throws: { error in
            guard case .responseTooLarge(_, _, 1000) = error as? VercelHTTPError else { return false }
            return true
        }
    }

    @Test func timesOut() async throws {
        let server = try await TestServer.start()
        defer { server.close() }
        let clock = ContinuousClock()
        let started = clock.now
        await #expect {
            _ = try await client.send(.get, "http://127.0.0.1:\(server.port)/hang", timeout: .milliseconds(200))
        } throws: { error in
            guard case .timedOut(_, _, .milliseconds(200)) = error as? VercelHTTPError else { return false }
            return true
        }
        #expect(clock.now - started < .seconds(5))
    }

    @Test func unreachableHostsAreTransportErrors() async throws {
        // Bind and close to find a port nothing listens on.
        let server = try await TestServer.start()
        let port = server.port
        server.close()
        await #expect {
            _ = try await client.send(.get, "http://127.0.0.1:\(port)/", timeout: .seconds(1))
        } throws: { error in
            guard case .transport = error as? VercelHTTPError else { return false }
            return true
        }
    }
}

/// A small HTTP/1.1 server on 127.0.0.1 with a random port.
///
/// - `/echo…` answers `201 Created` with the request's method, URI, `x-test` and `host` headers as
///   `x-method`, `x-uri`, `x-test`, `x-host`, two `set-cookie` fields, and the request body.
/// - `/redirect` answers `302` to `/echo?redirected=1`.
/// - `/bytes/<n>` answers with `n` bytes in chunks.
/// - `/hang` never answers.
struct TestServer {
    let channel: any Channel
    let port: Int

    static func start() async throws -> TestServer {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(Routes())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = try #require(channel.localAddress?.port)
        return TestServer(channel: channel, port: port)
    }

    func close() {
        channel.close(promise: nil)
    }

    final class Routes: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private var head: HTTPRequestHead?
        private var body = ByteBuffer()

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                self.head = head
                body.clear()
            case .body(var chunk):
                body.writeBuffer(&chunk)
            case .end:
                guard let head else { return }
                respond(to: head, context: context)
            }
        }

        private func respond(to head: HTTPRequestHead, context: ChannelHandlerContext) {
            var headers = HTTPHeaders()
            if head.uri.hasPrefix("/echo") {
                headers.add(name: "x-method", value: head.method.rawValue)
                headers.add(name: "x-uri", value: head.uri)
                headers.add(name: "x-test", value: head.headers["x-test"].first ?? "")
                headers.add(name: "x-host", value: head.headers["host"].first ?? "")
                headers.add(name: "set-cookie", value: "a=1")
                headers.add(name: "set-cookie", value: "b=2")
                headers.add(name: "content-length", value: String(body.readableBytes))
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: .created, headers: headers))), promise: nil)
                if head.method != .HEAD {
                    context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
                }
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            } else if head.uri == "/redirect" {
                headers.add(name: "location", value: "/echo?redirected=1")
                headers.add(name: "content-length", value: "0")
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: .found, headers: headers))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            } else if head.uri.hasPrefix("/bytes/"), let count = Int(head.uri.dropFirst("/bytes/".count)) {
                headers.add(name: "transfer-encoding", value: "chunked")
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: .ok, headers: headers))), promise: nil)
                var remaining = count
                while remaining > 0 {
                    let size = min(remaining, 300)
                    context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(repeating: 0x61, count: size)))), promise: nil)
                    remaining -= size
                }
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
            // `/hang`: no response.
        }
    }
}
