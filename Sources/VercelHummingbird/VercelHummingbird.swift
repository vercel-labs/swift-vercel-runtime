import HTTPTypes
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore
import ServiceLifecycle
@_exported import VercelRuntime

/// Wraps a Hummingbird responder (usually a `Router`) with the Vercel functions runtime contract.
///
/// - Answers `/_vercel/ping` health checks without touching the app.
/// - Removes the runtime's internal headers, exposing the OIDC token as `x-vercel-oidc-token`.
/// - Attributes ``VercelLogHandler`` logs to the request and tracks ``Vercel/waitUntil(_:)``.
/// - Sends the `end` IPC message once the responder returned or threw and `waitUntil` work is
///   done.
///
/// It wraps the whole responder rather than being a router middleware so unmatched routes are
/// covered too.
public struct VercelResponder<Inner: HTTPResponder>: HTTPResponder {
    public typealias Context = Inner.Context

    public let inner: Inner
    let runtime: VercelRuntime

    public init(_ inner: Inner, runtime: VercelRuntime = .shared) {
        self.inner = inner
        self.runtime = runtime
    }

    // `@concurrent` matches the isolation of Hummingbird's responders, so the non-Sendable
    // context is never sent across an isolation boundary.
    @Sendable @concurrent
    public func respond(to request: Request, context: Context) async throws -> Response {
        if request.uri.path == VercelHeader.pingPath {
            return Response(status: .ok, body: ResponseBody(byteBuffer: ByteBuffer(string: "OK")))
        }

        var head = request.head
        let invocation = head.headerFields.removeVercelInternalFields()
        let forwarded = head.headerFields == request.head.headerFields ? request : Request(head: head, body: request.body)
        return try await runtime.withRequest(invocation) {
            try await inner.respond(to: forwarded, context: context)
        }
    }
}

/// Protects cron routes: responds `401` unless the request carries
/// `Authorization: Bearer <CRON_SECRET>`. Allows every request when `CRON_SECRET` is not set.
///
/// ```swift
/// router.group("cron").add(middleware: VercelCronMiddleware()).get("cleanup") { _, _ in ... }
/// ```
public struct VercelCronMiddleware<Context>: RouterMiddleware {
    let secret: String?

    public init(secret: String? = VercelEnvironment.current.cronSecret) {
        self.secret = secret
    }

    // Hummingbird is compiled without `NonisolatedNonsendingByDefault`, so its async functions
    // and closures are `@concurrent`; spell that out to match the protocol requirement.
    @concurrent
    public func handle(
        _ request: Request,
        context: Context,
        next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard VercelCron.isAuthorized(request.headers, secret: secret) else {
            return Response(
                status: .unauthorized,
                headers: [.contentType: "application/json; charset=utf-8"],
                body: ResponseBody(byteBuffer: ByteBuffer(string: VercelCron.unauthorizedBody))
            )
        }
        return try await next(request, context)
    }
}

extension Request {
    /// Vercel-specific request information: geolocation, IP address, request id, OIDC token.
    public var vercel: VercelRequestInfo {
        headers.vercel
    }
}

extension Application {
    /// Creates an application that runs natively on Vercel's `executable` runtime.
    ///
    /// Takes the same arguments as `Application(router:...)`. Locally (no `VERCEL_IPC_PATH`) it
    /// behaves the same apart from answering `/_vercel/ping`. On Vercel it binds an ephemeral port
    /// on `127.0.0.1`, reports it to the functions runtime, and wraps the router in
    /// ``VercelResponder``.
    ///
    /// ```swift
    /// let router = Router()
    /// router.get("/") { _, _ in "Hello" }
    /// let app = Application(vercel: router)
    /// try await app.runService()
    /// ```
    public init<ResponderBuilder: HTTPResponderBuilder>(
        vercel router: ResponderBuilder,
        server: HTTPServerBuilder = .http1(),
        configuration: ApplicationConfiguration = ApplicationConfiguration(),
        services: [any Service] = [],
        onServerRunning: @escaping @Sendable (any Channel) async -> Void = { _ in },
        eventLoopGroupProvider: EventLoopGroupProvider = .singleton,
        logger: Logger? = nil,
        runtime: VercelRuntime = .shared
    ) where Responder == VercelResponder<ResponderBuilder.Responder> {
        var configuration = configuration
        if runtime.isEnabled {
            configuration.address = .hostname("127.0.0.1", port: 0)
        }
        self.init(
            responder: VercelResponder(router.buildResponder(), runtime: runtime),
            server: server,
            configuration: configuration,
            services: services,
            onServerRunning: { channel in
                if runtime.isEnabled {
                    if let port = channel.localAddress?.port {
                        runtime.serverStarted(httpPort: port)
                    } else {
                        await runtime.unrecoverableError(
                            message: "Hummingbird must listen on a TCP port on Vercel, got \(String(describing: channel.localAddress))"
                        )
                    }
                }
                await onServerRunning(channel)
            },
            eventLoopGroupProvider: eventLoopGroupProvider,
            logger: logger
        )
    }
}
