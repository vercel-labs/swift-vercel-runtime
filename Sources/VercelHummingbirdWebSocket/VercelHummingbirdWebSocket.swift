import HTTPTypes
import Hummingbird
import HummingbirdCore
@_exported import HummingbirdWebSocket
import Logging
import NIOCore
@_exported import VercelHummingbird

// WebSockets on Vercel
//
// The functions runtime proxies an HTTP/1.1 `Upgrade: websocket` request to the app's local
// server like any other request, always on a fresh connection (its client keeps no idle
// connections). Once the app answers `101 Switching Protocols` the platform tunnels the
// connection in both directions, so the invocation must report `end` at that point, not when the
// socket closes. This is the detached-upgrade flow of the Node.js, Python, Rust and Go runtimes.
//
// hummingbird-websocket decides on the upgrade at the channel level, before the HTTP responder
// (and so `VercelResponder`) sees the request, and answers both outcomes itself: `101` when it
// upgrades, a bare `400` when it declines. The HTTP responder never runs for a request that
// reached the upgrade decision, so the decision is wrapped in `withRequest`: internal headers are
// stripped and `end` is sent as soon as the decision returns, either way.

extension HTTPServerBuilder {
    /// HTTP/1.1 with WebSocket upgrades routed by `webSocketRouter`, wired for Vercel.
    ///
    /// Use instead of `.http1WebSocketUpgrade(webSocketRouter:configuration:)`:
    ///
    /// ```swift
    /// let wsRouter = Router(context: BasicWebSocketRequestContext.self)
    /// wsRouter.ws("/ws") { inbound, outbound, _ in
    ///     for try await message in inbound.messages(maxSize: 1 << 16) {
    ///         if case .text(let text) = message {
    ///             try await outbound.write(.text(text))
    ///         }
    ///     }
    /// }
    /// let app = Application(vercel: router, server: .vercelWebSocketUpgrade(webSocketRouter: wsRouter))
    /// ```
    public static func vercelWebSocketUpgrade<WSResponderBuilder: HTTPResponderBuilder & _HB_SendableMetatype>(
        webSocketRouter: WSResponderBuilder,
        configuration: HTTP1WebSocketUpgradeChannel.Configuration = .init(),
        runtime: VercelRuntime = .shared
    ) -> HTTPServerBuilder where WSResponderBuilder.Responder.Context: WebSocketRequestContext {
        .http1WebSocketUpgrade(
            webSocketRouter: VercelWebSocketRouter(router: webSocketRouter, runtime: runtime),
            configuration: configuration
        )
    }

    /// HTTP/1.1 with WebSocket upgrades decided by `shouldUpgrade`, wired for Vercel.
    ///
    /// Use instead of `.http1WebSocketUpgrade(configuration:shouldUpgrade:)`. `shouldUpgrade`
    /// receives the request head with the runtime's internal headers removed.
    public static func vercelWebSocketUpgrade(
        configuration: HTTP1WebSocketUpgradeChannel.Configuration = .init(),
        runtime: VercelRuntime = .shared,
        shouldUpgrade: @escaping @Sendable (HTTPRequest, any Channel, Logger) async throws -> ShouldUpgradeResult<
            WebSocketDataHandler<HTTP1WebSocketUpgradeChannel.Context>
        >
    ) -> HTTPServerBuilder {
        .http1WebSocketUpgrade(configuration: configuration) { head, channel, logger in
            var head = head
            let invocation = head.headerFields.removeVercelInternalFields()
            let forwarded = head
            return try await runtime.withRequest(invocation) {
                try await shouldUpgrade(forwarded, channel, logger)
            }
        }
    }
}

/// Builds a ``VercelWebSocketResponder`` around a WebSocket router.
struct VercelWebSocketRouter<Router: HTTPResponderBuilder & _HB_SendableMetatype>: HTTPResponderBuilder, _HB_SendableMetatype
where Router.Responder.Context: WebSocketRequestContext {
    let router: Router
    let runtime: VercelRuntime

    func buildResponder() -> VercelWebSocketResponder<Router.Responder> {
        VercelWebSocketResponder(router.buildResponder(), runtime: runtime)
    }
}

/// Wraps the responder hummingbird-websocket consults to decide on an upgrade, applying the
/// request contract to that decision.
public struct VercelWebSocketResponder<Inner: HTTPResponder>: HTTPResponder where Inner.Context: WebSocketRequestContext {
    public typealias Context = Inner.Context

    public let inner: Inner
    let runtime: VercelRuntime

    public init(_ inner: Inner, runtime: VercelRuntime = .shared) {
        self.inner = inner
        self.runtime = runtime
    }

    // `@concurrent` matches the isolation of Hummingbird's responders (see `VercelResponder`).
    @Sendable @concurrent
    public func respond(to request: Request, context: Context) async throws -> Response {
        var head = request.head
        let invocation = head.headerFields.removeVercelInternalFields()
        let forwarded = head.headerFields == request.head.headerFields ? request : Request(head: head, body: request.body)
        return try await runtime.withRequest(invocation) {
            try await inner.respond(to: forwarded, context: context)
        }
    }
}
