import Hummingbird
import HummingbirdWebSocket
import Logging
// `Vercel` is optional: it bundles VercelRuntime (per-request logs, `waitUntil`, request helpers)
// and the feature modules (Runtime Cache, Global Config, rate limiting, OIDC).
import Vercel

// A regular Hummingbird app: nothing here is required to run on Vercel. It listens on
// Hummingbird's default 127.0.0.1:8080, and the Vercel bootstrap finds it there.
@main
struct App {
    static func main() async throws {
        // Optional: groups logs by request in Vercel's logs (with the middleware below). Logs reach
        // Vercel without it too. If you already call LoggingSystem.bootstrap, add VercelLogHandler
        // there with MultiplexLogHandler instead.
        VercelLogHandler.bootstrap()

        let router = Router()
        // Runs every route as part of its Vercel request (logs, waitUntil and the feature modules
        // below). See below.
        router.add(middleware: VercelRequestMiddleware())
        let region = Environment().get("VERCEL_REGION")
        let logger = Logger(label: "app")

        router.get("/") { _, _ in
            "Hello from Hummingbird 2 running natively on Vercel (\(architecture), \(linkage))\n"
        }

        router.get("hello/:name") { _, context in
            "Hello, \(try context.parameters.require("name"))!\n"
        }

        router.get("json") { _, _ in
            Info(message: "Hello from Swift", framework: "Hummingbird 2", architecture: architecture, region: region)
        }

        // Echoes request header names so the header stripping can be checked end to end.
        router.get("headers") { request, _ in
            request.headers.map { $0.name.canonicalName }.sorted()
        }

        // What VercelRuntime knows about the current request, for the contract checks: the header
        // names (never their values) and the deadline.
        router.get("request-context") { request, _ in
            RequestContextDetails(
                headers: request.headers.map { $0.name.canonicalName }.sorted(),
                deadline: request.headers[.init("x-vercel-deadline")!],
                deadlineMilliseconds: Vercel.deadline.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) }
            )
        }

        // Reports an outbound request, shown under External APIs in Vercel's Observability.
        router.get("fetch-metric") { _, _ in
            Vercel.reportFetch(method: "GET", host: "example.com", path: "/v1/x", query: "a=1", statusCode: 200, duration: .milliseconds(45))
            return "reported\n"
        }

        // MARK: Vercel feature modules
        //
        // For end-to-end tests on a deployment: every route answers JSON describing what happened,
        // with errors as strings instead of failing the request.

        // Runtime Cache. Without a cache from Vercel (locally, for example) it is in memory.
        let cache = RuntimeCache(namespace: "hello-hummingbird")

        router.get("cache/:key") { _, context in
            var result = CacheResult(operation: "get")
            result.key = try context.parameters.require("key")
            do {
                result.value = try await cache.get(result.key ?? "", as: String.self)
                result.hit = result.value != nil
            } catch {
                result.error = "\(error)"
            }
            return result
        }

        // PUT or POST /cache/:key?value=...&ttl=<seconds>&tags=a,b
        let setCache: @Sendable (Request, BasicRequestContext) async throws -> CacheResult = { request, context in
            var result = CacheResult(operation: "set")
            result.key = try context.parameters.require("key")
            result.value = request.uri.queryParameters.get("value") ?? ""
            result.ttl = request.uri.queryParameters.get("ttl", as: Int.self)
            result.tags = (request.uri.queryParameters.get("tags") ?? "").split(separator: ",").map(String.init)
            do {
                try await cache.set(
                    result.key ?? "", result.value ?? "", ttl: result.ttl.map { .seconds($0) }, tags: result.tags ?? [])
            } catch {
                result.error = "\(error)"
            }
            return result
        }
        router.put("cache/:key", use: setCache)
        router.post("cache/:key", use: setCache)

        router.post("cache-expire/:tag") { _, context in
            var result = CacheResult(operation: "expireTag")
            result.tags = [try context.parameters.require("tag")]
            do {
                try await cache.expireTag(result.tags ?? [])
            } catch {
                result.error = "\(error)"
            }
            return result
        }

        // Global Config, from the store connected to the project (EDGE_CONFIG).
        router.get("global-config/:key") { _, context in
            var result = GlobalConfigResult()
            result.key = try context.parameters.require("key")
            do {
                let config = try GlobalConfig.default
                result.store = config.connection.id
                result.value = try await config.get(result.key ?? "")
                result.found = result.value != nil
            } catch {
                result.error = describeGlobalConfigError(error)
            }
            return result
        }

        router.get("global-config") { _, _ in
            var result = GlobalConfigResult()
            do {
                let config = try GlobalConfig.default
                result.store = config.connection.id
                result.items = try await config.getAll()
                result.digest = try await config.digest()
            } catch {
                result.error = describeGlobalConfigError(error)
            }
            return result
        }

        // Rate limiting with the Vercel Firewall rule whose rate limit ID is :id. `key` overrides the
        // client IP as the rate limit key.
        router.get("rate-limit/:id") { request, context in
            var result = RateLimitDetails(id: try context.parameters.require("id"))
            do {
                let check = try await Firewall.checkRateLimit(
                    result.id, rateLimitKey: request.uri.queryParameters.get("key"))
                result.rateLimited = check.rateLimited
                result.reason = check.reason?.rawValue
            } catch {
                result.error = "\(error)"
            }
            return result
        }

        // The OIDC token's claims (never the token itself).
        router.get("oidc") { request, _ in
            var result = OIDCDetails()
            result.source = request.headers[.init("x-vercel-oidc-token")!] != nil ? "request" : "environment"
            do {
                let token = try VercelOIDCToken(OIDC.token())
                result.issuer = token.issuer
                result.subject = token.subject
                result.audience = token.audience
                result.expiresAt = token.expiresAt.map { Int($0.timeIntervalSince1970) }
                result.expired = token.isExpired()
                result.owner = token.owner
                result.ownerID = token.ownerID
                result.project = token.project
                result.projectID = token.projectID
                result.environment = token.environment
            } catch {
                result.source = nil
                result.error = "\(error)"
            }
            return result
        }

        // Streams chunks over time to exercise Vercel response streaming.
        router.get("stream") { _, _ in
            Response(
                status: .ok,
                headers: [.contentType: "text/plain; charset=utf-8"],
                body: ResponseBody { writer in
                    for index in 1...5 {
                        try await writer.write(ByteBuffer(string: "chunk \(index)\n"))
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    try await writer.finish(nil)
                }
            )
        }

        router.get("error") { _, _ -> String in
            throw HTTPError(.internalServerError, message: "Intentional error")
        }

        // Shows up under this request in Vercel's logs, with the warning level.
        router.get("log") { _, _ in
            logger.warning("hello from swift-log", metadata: ["route": "log"])
            return "logged\n"
        }

        // Responds immediately; the function keeps running until the background work is done.
        router.get("wait-until/:ms") { _, context in
            let milliseconds = try context.parameters.require("ms", as: Int.self)
            Vercel.waitUntil {
                do {
                    try await Task.sleep(for: .milliseconds(milliseconds))
                    logger.info("background work done")
                } catch {
                    logger.warning("background work cancelled")
                    throw error
                }
            }
            return "scheduled\n"
        }

        // Scheduled from vercel.json. With CRON_SECRET set, Vercel's bootstrap rejects requests
        // without `Authorization: Bearer $CRON_SECRET` before they get here.
        router.get("cron") { _, _ in
            logger.info("cron job ran")
            return "cron ok\n"
        }

        router.get("geo") { request, _ in
            let environment = VercelEnvironment.current
            let vercel = request.headers.vercel
            return RequestDetails(
                id: vercel.id,
                ipAddress: vercel.ipAddress,
                geolocation: vercel.geolocation,
                environment: environment.target?.rawValue,
                region: environment.region
            )
        }

        // WebSockets: echo every text/binary message back to the client.
        let webSocketRouter = Router(context: BasicWebSocketRequestContext.self)
        webSocketRouter.ws("ws") { inbound, outbound, _ in
            for try await message in inbound.messages(maxSize: 1 << 16) {
                switch message {
                case .text(let text): try await outbound.write(.text(text))
                case .binary(let bytes): try await outbound.write(.binary(bytes))
                }
            }
        }

        // A minimal browser client for /ws.
        router.get("ws-demo") { _, _ in
            Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: ResponseBody(byteBuffer: ByteBuffer(string: webSocketDemoPage))
            )
        }

        let app = Application(router: router, server: .http1WebSocketUpgrade(webSocketRouter: webSocketRouter))
        try await app.runService()
    }
}

/// Runs each request inside `Vercel.withRequest`, so `VercelLogHandler` attributes its logs to it,
/// `Vercel.waitUntil` keeps the function alive for its background work, and the feature modules
/// find the request's headers (Runtime Cache location, OIDC token, client IP). Locally it only sets
/// `Vercel.currentRequest`.
struct VercelRequestMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        try await Vercel.withRequest(request.headers) {
            try await next(request, context)
        }
    }
}

struct Info: ResponseEncodable {
    var message: String
    var framework: String
    var architecture: String
    var region: String?
}

struct RequestContextDetails: ResponseEncodable {
    var headers: [String]
    var deadline: String?
    var deadlineMilliseconds: Int?
}

struct CacheResult: ResponseEncodable {
    var operation: String
    var key: String?
    var value: String?
    var hit: Bool?
    /// Seconds.
    var ttl: Int?
    var tags: [String]?
    var error: String?
}

struct GlobalConfigResult: ResponseEncodable {
    /// The store's ID.
    var store: String?
    var key: String?
    var found: Bool?
    var value: GlobalConfigValue?
    var items: [String: GlobalConfigValue]?
    var digest: String?
    var error: String?
}

func describeGlobalConfigError(_ error: any Error) -> String {
    if case GlobalConfigError.missingConnectionString = error {
        return "EDGE_CONFIG is not set: connect a Global Config store to the project"
    }
    return "\(error)"
}

struct RateLimitDetails: ResponseEncodable {
    var id: String
    var rateLimited: Bool?
    /// `RateLimitResult.Reason`: `not-found` (no rule with this ID) or `blocked`.
    var reason: String?
    var error: String?
}

struct OIDCDetails: ResponseEncodable {
    /// Where the token came from: the `request` header or the `environment` (VERCEL_OIDC_TOKEN).
    var source: String?
    var issuer: String?
    var subject: String?
    var audience: [String]?
    /// Unix seconds.
    var expiresAt: Int?
    var expired: Bool?
    var owner: String?
    var ownerID: String?
    var project: String?
    var projectID: String?
    var environment: String?
    var error: String?
}

struct RequestDetails: ResponseEncodable {
    var id: String?
    var ipAddress: String?
    var geolocation: VercelGeolocation
    var environment: String?
    var region: String?
}

let webSocketDemoPage = """
    <!doctype html>
    <meta charset="utf-8">
    <title>Swift WebSocket on Vercel</title>
    <h1>Swift WebSocket on Vercel</h1>
    <form id="form"><input id="input" autocomplete="off" placeholder="message"> <button>Send</button></form>
    <pre id="log"></pre>
    <script>
      const log = (line) => (document.getElementById("log").textContent += line + "\\n");
      const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
      ws.onopen = () => log("connected");
      ws.onmessage = (event) => log("echo: " + event.data);
      ws.onclose = (event) => log("closed " + event.code);
      document.getElementById("form").onsubmit = (event) => {
        event.preventDefault();
        const input = document.getElementById("input");
        ws.send(input.value);
        input.value = "";
      };
    </script>
    """

#if arch(arm64)
let architecture = "arm64"
#elseif arch(x86_64)
let architecture = "x86_64"
#else
let architecture = "unknown"
#endif

#if canImport(Musl)
let linkage = "static musl binary"
#else
let linkage = "native binary"
#endif
