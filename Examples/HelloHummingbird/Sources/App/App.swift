import Hummingbird
import HummingbirdWebSocket
import Logging
import VercelRuntime

// A regular Hummingbird app: nothing here is required to run on Vercel. It listens on
// Hummingbird's default 127.0.0.1:8080, and the Vercel bootstrap finds it there.
//
// `VercelRuntime` is optional. It is used here for per-request logs, `waitUntil` and the request
// helpers.
@main
struct App {
    static func main() async throws {
        // Attributes logs to the request that produced them in Vercel's logs.
        VercelLogHandler.bootstrap()

        let router = Router()
        // Runs every route as part of its Vercel request (logs and waitUntil). See below.
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

/// Runs each request inside `Vercel.withRequest`, so `VercelLogHandler` attributes its logs to it
/// and `Vercel.waitUntil` keeps the function alive for its background work. Locally it does nothing.
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
