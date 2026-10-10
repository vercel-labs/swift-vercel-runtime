import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOPosix
import VercelRuntime

/// What the proxy needs to know.
package struct ProxyConfiguration: Sendable {
    /// Where the app listens.
    package var upstream: SocketAddress
    package var tracker: RequestTracker
    /// The deployment's bootstrap configuration (cron paths).
    package var bootstrap: BootstrapConfiguration
    /// `CRON_SECRET`: when set, requests to cron paths need `Authorization: Bearer <secret>`.
    package var cronSecret: String?

    package init(upstream: SocketAddress, tracker: RequestTracker, configuration: BootstrapConfiguration, cronSecret: String?) {
        self.upstream = upstream
        self.tracker = tracker
        self.bootstrap = configuration
        self.cronSecret = cronSecret
    }
}

/// The HTTP server the functions runtime talks to. Each runtime connection gets its own
/// connection to the app, so requests, streamed responses and WebSocket tunnels map one to one.
package enum ProxyServer {
    package static func bind(
        host: String = "127.0.0.1",
        port: Int = 0,
        configuration: ProxyConfiguration,
        group: any EventLoopGroup
    ) async throws -> any Channel {
        try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 1024)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withPipeliningAssistance: true,
                        withErrorHandling: true
                    )
                    try channel.pipeline.syncOperations.addHandler(ProxyHandler(configuration: configuration))
                }
            }
            .bind(host: host, port: port)
            .get()
    }
}

/// Rewrites request headers for the app: removes the runtime's internal headers (exposing the
/// OIDC token as `x-vercel-oidc-token`) and any client-supplied bootstrap token.
///
/// Returns the headers to forward, as `HTTPFields`, and the invocation the request belongs to.
package func rewriteRequestHeaders(_ headers: HTTPHeaders) -> (HTTPFields, InvocationContext?) {
    var fields = HTTPFields()
    fields.reserveCapacity(headers.count)
    for (name, value) in headers {
        // NIO's parser only accepts valid field names, so nothing is dropped in practice.
        if let fieldName = HTTPField.Name(name) {
            fields.append(HTTPField(name: fieldName, value: value))
        }
    }
    fields[.bootstrapRequest] = nil
    let invocation = fields.removeVercelInternalFields()
    return (fields, invocation)
}

extension HTTPField.Name {
    static let bootstrapRequest = Self(BootstrapProtocol.requestHeader)!
}

extension HTTPHeaders {
    init(_ fields: HTTPFields) {
        self.init()
        reserveCapacity(fields.count)
        for field in fields {
            add(name: field.name.rawName, value: field.value)
        }
    }
}

/// The runtime's side of one proxied connection: the last handler of the HTTP server pipeline.
///
/// - Answers `/_vercel/ping` and rejects unauthorized cron requests itself.
/// - Forwards everything else to the app over a dedicated connection, streaming bodies in both
///   directions with backpressure (reads on one side wait for the other side to be writable).
/// - Reports each request to the ``RequestTracker`` once its response has been fully proxied.
/// - On `101 Switching Protocols` it replaces both HTTP pipelines with a byte tunnel.
final class ProxyHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    private enum Upstream {
        case idle
        case connecting(buffered: [HTTPClientRequestPart])
        case connected(any Channel, UpstreamHandler)
    }

    /// The request currently being handled. `HTTPServerPipelineHandler` delivers one at a time.
    private struct Exchange {
        var token: String?
        /// `false` once the bootstrap answers the request itself: the rest of it is discarded.
        var forwarding: Bool
        var isUpgradeRequest: Bool
        var requestKeepAlive: Bool
        var version: HTTPVersion
        var responseStarted = false
        var responseKeepAlive = true
        var switchingProtocols = false
        var responseEnded = false
    }

    private let configuration: ProxyConfiguration
    private var context: ChannelHandlerContext?
    private var upstream = Upstream.idle
    private var exchange: Exchange?
    private var pendingRead = false

    init(configuration: ProxyConfiguration) {
        self.configuration = configuration
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    // MARK: Requests from the runtime

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            startExchange(head, context: context)
        case .body(let body):
            if exchange?.forwarding == true {
                sendUpstream(.body(.byteBuffer(body)))
            }
        case .end(let trailers):
            if exchange?.forwarding == true {
                sendUpstream(.end(trailers))
            }
        }
    }

    private func startExchange(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        let isUpgradeRequest =
            head.headers.contains(name: "upgrade")
            && head.headers[canonicalForm: "connection"].contains { $0.lowercased() == "upgrade" }
        var exchange = Exchange(
            token: nil,
            forwarding: false,
            isUpgradeRequest: isUpgradeRequest,
            requestKeepAlive: head.isKeepAlive,
            version: head.version
        )
        let path = normalizedPath(head.uri)

        // Health checks never reach the app and produce no IPC traffic.
        if path == VercelHeader.pingPath {
            self.exchange = exchange
            respondLocally(status: .ok, contentType: "text/plain; charset=utf-8", body: "OK")
            return
        }

        let (fields, invocation) = rewriteRequestHeaders(head.headers)
        var forwarded = fields
        if let invocation {
            let token = configuration.tracker.begin(invocation)
            exchange.token = token
            forwarded[.bootstrapRequest] = token
        }

        if configuration.bootstrap.isCronPath(path), let secret = configuration.cronSecret, !secret.isEmpty,
            !VercelCron.isAuthorized(fields, secret: secret)
        {
            self.exchange = exchange
            respondLocally(status: .unauthorized, contentType: "application/json; charset=utf-8", body: VercelCron.unauthorizedBody)
            return
        }

        exchange.forwarding = true
        self.exchange = exchange
        var request = head
        request.headers = HTTPHeaders(forwarded)
        sendUpstream(.head(request))
    }

    private func sendUpstream(_ part: HTTPClientRequestPart) {
        switch upstream {
        case .connected(let channel, _):
            channel.writeAndFlush(part, promise: nil)
        case .connecting(var buffered):
            buffered.append(part)
            upstream = .connecting(buffered: buffered)
        case .idle:
            // Only a new request opens a connection; the rest of a request whose connection
            // failed is dropped (it has already been answered).
            guard case .head = part else { return }
            upstream = .connecting(buffered: [part])
            connectUpstream()
        }
    }

    private func connectUpstream() {
        guard let context else { return }
        let loop = context.eventLoop
        let proxy = NIOLoopBound(self, eventLoop: loop)
        ClientBootstrap(group: loop)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        HTTPRequestEncoder(),
                        ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)),
                        UpstreamHandler(proxy: proxy.value),
                    ])
                }
            }
            .connect(to: configuration.upstream)
            .assumeIsolated()
            .whenComplete { result in
                proxy.value.upstreamConnected(result)
            }
    }

    private func upstreamConnected(_ result: Result<any Channel, any Error>) {
        guard case .connecting(let buffered) = upstream else {
            // The runtime's connection closed while connecting.
            if case .success(let channel) = result {
                channel.close(promise: nil)
            }
            return
        }
        switch result {
        case .success(let channel):
            guard let handler = try? channel.pipeline.syncOperations.handler(type: UpstreamHandler.self) else {
                channel.close(promise: nil)
                upstream = .idle
                failExchange(reason: "the app connection could not be set up")
                return
            }
            upstream = .connected(channel, handler)
            for part in buffered {
                channel.write(part, promise: nil)
            }
            channel.flush()
            readIfPossible()
        case .failure(let error):
            upstream = .idle
            failExchange(reason: "cannot connect to the app at \(configuration.upstream): \(error)")
        }
    }

    // MARK: Responses from the app

    func upstreamRead(_ part: HTTPClientResponsePart) {
        guard let context, var exchange, !exchange.responseEnded else { return }
        switch part {
        case .head(let head):
            exchange.responseStarted = true
            exchange.responseKeepAlive = head.isKeepAlive
            exchange.switchingProtocols = head.status == .switchingProtocols && exchange.isUpgradeRequest
            self.exchange = exchange
            context.write(wrapOutboundOut(.head(head)), promise: nil)
        case .body(let body):
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        case .end(let trailers):
            let written = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(wrapOutboundOut(.end(trailers)), promise: written)
            responseEnded(written: written.futureResult)
        }
    }

    func upstreamReadComplete() {
        context?.flush()
    }

    func upstreamWritabilityChanged() {
        readIfPossible()
    }

    func upstreamClosed() {
        upstream = .idle
        guard let context, let exchange, exchange.forwarding, !exchange.responseEnded else { return }
        if exchange.responseStarted {
            // The response was cut off; the runtime's connection cannot be reused.
            context.close(promise: nil)
        } else {
            failExchange(reason: "the app closed the connection without responding")
        }
    }

    var isWritable: Bool {
        context?.channel.isWritable ?? false
    }

    // MARK: Ending requests

    /// Answers the current request from the bootstrap.
    private func respondLocally(status: HTTPResponseStatus, contentType: String, body: String) {
        guard let context, var exchange else { return }
        exchange.forwarding = false
        exchange.responseStarted = true
        self.exchange = exchange
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: contentType)
        headers.add(name: "content-length", value: String(body.utf8.count))
        if !exchange.requestKeepAlive || exchange.isUpgradeRequest {
            headers.add(name: "connection", value: "close")
        }
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: exchange.version, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: body)))), promise: nil)
        let written = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: written)
        responseEnded(written: written.futureResult)
    }

    private func failExchange(reason: String) {
        guard let exchange, !exchange.responseEnded else { return }
        writeToStandardError("[vercel] \(reason)")
        if exchange.responseStarted {
            context?.close(promise: nil)
        } else {
            respondLocally(status: .badGateway, contentType: "text/plain; charset=utf-8", body: "Bad Gateway")
        }
    }

    private func responseEnded(written: EventLoopFuture<Void>) {
        guard let context, var exchange else { return }
        exchange.responseEnded = true
        let token = exchange.token
        exchange.token = nil
        self.exchange = exchange
        if let token {
            configuration.tracker.responseFinished(token: token)
        }

        if exchange.switchingProtocols {
            startTunnel(context: context)
            return
        }
        // After an upgrade request the HTTP decoder stops parsing, so a declined upgrade also
        // ends the connection.
        if !exchange.requestKeepAlive || !exchange.responseKeepAlive || exchange.isUpgradeRequest {
            let channel = context.channel
            written.whenComplete { _ in channel.close(promise: nil) }
            closeUpstream()
            return
        }
        readIfPossible()
    }

    private func closeUpstream() {
        if case .connected(let channel, _) = upstream {
            channel.close(promise: nil)
        }
        upstream = .idle
    }

    // MARK: WebSockets

    /// Replaces the HTTP handlers on both connections with a byte tunnel. The request already
    /// ended (the runtime tunnels the connection on its own after `101`).
    private func startTunnel(context: ChannelHandlerContext) {
        guard case .connected(let upstreamChannel, let upstreamHandler) = upstream else {
            context.close(promise: nil)
            return
        }
        upstream = .idle
        let inbound = context.pipeline.syncOperations
        let outbound = upstreamChannel.pipeline.syncOperations
        let inboundChannel = context.channel
        do {
            let (inboundGlue, outboundGlue) = GlueHandler.matchedPair()
            try inbound.addHandler(inboundGlue)
            try outbound.addHandler(outboundGlue)

            // Encoders and HTTP handlers first, then this handler, then the decoders: removing a
            // decoder forwards the bytes it buffered after the upgrade to the glue, which writes
            // them raw to the other side.
            _ = outbound.removeHandler(try outbound.handler(type: HTTPRequestEncoder.self))
            _ = outbound.removeHandler(upstreamHandler)
            _ = inbound.removeHandler(try inbound.handler(type: HTTPResponseEncoder.self))
            _ = inbound.removeHandler(try inbound.handler(type: HTTPServerPipelineHandler.self))
            _ = inbound.removeHandler(try inbound.handler(type: HTTPServerProtocolErrorHandler.self))
            if let validator = try? inbound.handler(type: NIOHTTPResponseHeadersValidator.self) {
                _ = inbound.removeHandler(validator)
            }
            _ = inbound.removeHandler(context: context)
            _ = outbound.removeHandler(try outbound.handler(type: ByteToMessageHandler<HTTPResponseDecoder>.self))
            _ = inbound.removeHandler(try inbound.handler(type: ByteToMessageHandler<HTTPRequestDecoder>.self))
        } catch {
            writeToStandardError("[vercel] could not start the WebSocket tunnel: \(error)")
            inboundChannel.close(promise: nil)
            upstreamChannel.close(promise: nil)
            return
        }
        inboundChannel.read()
        upstreamChannel.read()
    }

    // MARK: Connection events

    func channelInactive(context: ChannelHandlerContext) {
        if let token = exchange?.token {
            exchange?.token = nil
            configuration.tracker.responseFinished(token: token)
        }
        closeUpstream()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable, case .connected(_, let handler) = upstream {
            handler.proxyBecameWritable()
        }
        context.fireChannelWritabilityChanged()
    }

    /// Reads from the runtime only while the app connection can take more data.
    func read(context: ChannelHandlerContext) {
        if canRead {
            context.read()
        } else {
            pendingRead = true
        }
    }

    private var canRead: Bool {
        switch upstream {
        case .idle: true
        case .connecting: false
        case .connected(let channel, _): channel.isWritable
        }
    }

    private func readIfPossible() {
        guard pendingRead, canRead, let context else { return }
        pendingRead = false
        context.read()
    }
}

/// The app's side of one proxied connection.
final class UpstreamHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    private weak var proxy: ProxyHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    init(proxy: ProxyHandler) {
        self.proxy = proxy
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.proxy = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        proxy?.upstreamRead(unwrapInboundIn(data))
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        proxy?.upstreamReadComplete()
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        proxy?.upstreamClosed()
        context.fireChannelInactive()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            proxy?.upstreamWritabilityChanged()
        }
        context.fireChannelWritabilityChanged()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    /// Reads from the app only while the runtime's connection can take more data.
    func read(context: ChannelHandlerContext) {
        if proxy?.isWritable ?? true {
            context.read()
        } else {
            pendingRead = true
        }
    }

    func proxyBecameWritable() {
        guard pendingRead, let context else { return }
        pendingRead = false
        context.read()
    }
}

/// Copies bytes between two channels in both directions, with backpressure: a side only reads
/// while the other side is writable. Used for WebSocket tunnels.
final class GlueHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }

    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerClose() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        guard pendingRead, let context else { return }
        pendingRead = false
        context.read()
    }

    private var partnerIsWritable: Bool {
        context?.channel.isWritable ?? false
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerClose()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if partner?.partnerIsWritable ?? false {
            context.read()
        } else {
            pendingRead = true
        }
    }
}
