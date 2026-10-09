import Configuration
import HTTPTypes
import Synchronization
import Vapor
@_exported import VercelRuntime

extension Application {
    /// Creates an `Application` that runs natively on Vercel's `executable` runtime.
    ///
    /// Locally (no `VERCEL_IPC_PATH`) this behaves like `Application(...)`. On Vercel it binds an
    /// ephemeral port on `127.0.0.1`, reports it to the functions runtime, and installs
    /// ``VercelMiddleware``.
    public static func vercel(
        _ environment: Environment? = nil,
        configuration: ServerConfiguration = .init(),
        providers: [any ConfigProvider] = [CommandLineArgumentsProvider(), EnvironmentVariablesProvider()],
        services: ServiceConfiguration = .init(),
        runtime: VercelRuntime = .shared
    ) throws -> Application {
        let app = try Application(
            environment,
            configuration: configuration,
            configReader: ConfigReader.vercel(providers: providers, runtime: runtime),
            services: services
        )
        app.useVercel(runtime: runtime)
        return app
    }

    /// Installs the Vercel integration on an existing application.
    ///
    /// If you build the `Application` yourself, also pass ``ConfigReader/vercel(providers:runtime:)``
    /// so `PORT`/`HOSTNAME` style settings cannot move the server off `127.0.0.1`.
    public func useVercel(runtime: VercelRuntime = .shared) {
        self.middleware.use(VercelMiddleware(runtime: runtime), at: .beginning)
        guard runtime.isEnabled else { return }
        self.serverConfiguration.address = .hostname("127.0.0.1", port: 0)
        self.addLifecycleHandler(VercelLifecycleHandler(runtime: runtime))
    }
}

extension ConfigReader {
    /// A config reader that, on Vercel, forces the server address and defaults to production.
    ///
    /// Vapor applies `hostname`/`port` from configuration after `configure` runs, so a stray
    /// `PORT` or `HOSTNAME` environment variable would otherwise override the bind address the
    /// functions runtime needs. Off Vercel, this is just `ConfigReader(providers:)`.
    public static func vercel(
        providers: [any ConfigProvider] = [CommandLineArgumentsProvider(), EnvironmentVariablesProvider()],
        runtime: VercelRuntime = .shared
    ) -> ConfigReader {
        guard runtime.isEnabled else {
            return ConfigReader(providers: providers)
        }
        let overrides = InMemoryProvider(name: "vercel", values: [
            "hostname": "127.0.0.1",
            "port": 0,
        ])
        let defaults = InMemoryProvider(name: "vercel-defaults", values: [
            "vapor.env": "production",
        ])
        return ConfigReader(providers: [overrides] + providers + [defaults])
    }
}

/// Implements the per-request part of the Vercel functions runtime contract.
///
/// - Answers `/_vercel/ping` health checks without touching the app.
/// - Removes the runtime's internal headers, exposing the OIDC token as `x-vercel-oidc-token`.
/// - Attributes ``VercelLogHandler`` logs to the request and tracks ``Vercel/waitUntil(_:)``.
/// - Sends the `end` IPC message once the handler returned or threw and `waitUntil` work is done.
///
/// `end` only tells the runtime there is no more background work for the request; the runtime
/// tracks the response body itself, so streamed bodies keep flowing after `end` is sent.
public struct VercelMiddleware: Middleware {
    let runtime: VercelRuntime

    public init(runtime: VercelRuntime = .shared) {
        self.runtime = runtime
    }

    public func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        if request.url.path == VercelHeader.pingPath {
            return Response(status: .ok, body: "OK")
        }

        var stripped = request
        let context = stripped.headers.removeVercelInternalFields()
        let forwarded = stripped
        return try await runtime.withRequest(context) {
            try await next.respond(to: forwarded)
        }
    }
}

/// Protects cron routes: responds `401` unless the request carries
/// `Authorization: Bearer <CRON_SECRET>`. Allows every request when `CRON_SECRET` is not set.
///
/// ```swift
/// app.grouped(VercelCronMiddleware()).get("cron", "cleanup") { _ in ... }
/// ```
public struct VercelCronMiddleware: Middleware {
    let secret: String?

    public init(secret: String? = VercelEnvironment.current.cronSecret) {
        self.secret = secret
    }

    public func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        guard VercelCron.isAuthorized(request.headers, secret: secret) else {
            var headers = HTTPFields()
            headers[.contentType] = "application/json; charset=utf-8"
            return Response(status: .unauthorized, headers: headers, body: .init(string: VercelCron.unauthorizedBody))
        }
        return try await next.respond(to: request)
    }
}

extension Request {
    /// Vercel-specific request information: geolocation, IP address, request id, OIDC token.
    public var vercel: VercelRequestInfo {
        headers.vercel
    }
}

/// Sends `server-started` once Vapor's server is listening.
final class VercelLifecycleHandler: LifecycleHandler {
    let runtime: VercelRuntime
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(runtime: VercelRuntime) {
        self.runtime = runtime
    }

    func didBoot(_ application: Application) async throws {
        let server = application.server
        let runtime = self.runtime
        let task = Task {
            do {
                let address = try await server.listeningAddress
                guard let port = address.port else {
                    await runtime.unrecoverableError(message: "Vapor must listen on a TCP port on Vercel, got \(address)")
                    return
                }
                runtime.serverStarted(httpPort: port)
            } catch {
                await runtime.unrecoverableError(message: "Vapor server failed to start: \(error)")
            }
        }
        self.task.withLock { $0 = task }
    }

    func shutdown(_ application: Application) async {
        self.task.withLock { $0?.cancel() }
    }
}
