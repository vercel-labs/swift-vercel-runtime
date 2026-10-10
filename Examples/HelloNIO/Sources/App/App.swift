#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import NIOCore
import NIOHTTP1
import NIOPosix

// A plain HTTP server written directly on SwiftNIO, with no Vercel code or dependency: it listens
// on PORT (8080 by default), like any server would on any host.
@main
struct App {
    static func main() async throws {
        let port = getenv("PORT").flatMap { Int(String(cString: $0)) } ?? 8080
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(Routes())
                }
            }
            .bind(host: "127.0.0.1", port: port)
            .get()
        print("Listening on http://127.0.0.1:\(port)")
        try await server.closeFuture.get()
    }
}

final class Routes: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var head: HTTPRequestHead?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
        case .body:
            break
        case .end:
            guard let head else { return }
            respond(to: head, context: context)
        }
    }

    private func respond(to head: HTTPRequestHead, context: ChannelHandlerContext) {
        let path = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        switch path {
        case "/":
            send("Hello from SwiftNIO running natively on Vercel\n", context: context)
        case "/headers":
            // Request header names, so the header stripping can be checked end to end.
            let names = head.headers.map { "\"\($0.name.lowercased())\"" }.sorted()
            send("[\(names.joined(separator: ","))]", contentType: "application/json", context: context)
        case "/cron":
            send("cron ok\n", context: context)
        case "/error":
            send("Intentional error\n", status: .internalServerError, context: context)
        case "/stream":
            stream(chunks: 5, context: context)
        case _ where path.hasPrefix("/hello/"):
            send("Hello, \(path.dropFirst("/hello/".count))!\n", context: context)
        default:
            send("Not Found\n", status: .notFound, context: context)
        }
    }

    private func send(
        _ body: String,
        status: HTTPResponseStatus = .ok,
        contentType: String = "text/plain; charset=utf-8",
        context: ChannelHandlerContext
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: contentType)
        headers.add(name: "content-length", value: String(body.utf8.count))
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: body)))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    /// Streams chunks over time, to exercise response streaming.
    private func stream(chunks: Int, context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/plain; charset=utf-8")
        context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        let routes = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        func write(_ index: Int) {
            let context = boundContext.value
            guard index <= chunks else {
                context.writeAndFlush(routes.value.wrapOutboundOut(.end(nil)), promise: nil)
                return
            }
            context.writeAndFlush(routes.value.wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "chunk \(index)\n")))), promise: nil)
            context.eventLoop.assumeIsolated().scheduleTask(in: .milliseconds(200)) { write(index + 1) }
        }
        write(1)
    }
}
