import Logging
import Vapor
import VercelRuntime

// A regular Vapor 5 app: nothing here is required to run on Vercel. Vapor reads the PORT
// environment variable, which the Vercel bootstrap sets.
//
// `VercelRuntime` is optional. It is used here for per-request logs, `waitUntil` and the request
// helpers.
@main
struct App {
    static func main() async throws {
        // Optional: groups logs by request in Vercel's logs (with the middleware below). Logs reach
        // Vercel without it too. If you already call LoggingSystem.bootstrap, add VercelLogHandler
        // there with MultiplexLogHandler instead.
        VercelLogHandler.bootstrap()

        let app = try Application()
        // Runs every route as part of its Vercel request (logs and waitUntil). See below.
        app.middleware.use(VercelRequestMiddleware())
        try routes(app)
        try await app.start()
    }
}

/// Runs each request inside `Vercel.withRequest`, so `VercelLogHandler` attributes its logs to it
/// and `Vercel.waitUntil` keeps the function alive for its background work. Locally it does nothing.
struct VercelRequestMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        try await Vercel.withRequest(request.headers) {
            try await next.respond(to: request)
        }
    }
}

struct Info: Content {
    var message: String
    var framework: String
    var architecture: String
    var region: String?
}

struct RequestDetails: Content {
    var id: String?
    var ipAddress: String?
    var geolocation: VercelGeolocation
    var environment: String?
    var region: String?
}

let logger = Logger(label: "app")

func routes(_ app: Application) throws {
    let region = app.configReader.string(forKey: "vercel.region")

    app.get { _ in
        "Hello from Vapor 5 running natively on Vercel (\(architecture), \(linkage))\n"
    }

    app.get("hello", ":name") { req in
        let name = try req.parameters.require("name")
        return "Hello, \(name)!\n"
    }

    app.get("json") { _ in
        Info(
            message: "Hello from Swift",
            framework: "Vapor 5.0.0-beta.3",
            architecture: architecture,
            region: region
        )
    }

    // Echoes request header names so the header stripping can be checked end to end.
    app.get("headers") { req in
        req.headers.map { $0.name.canonicalName }.sorted()
    }

    // Streams chunks over time to exercise Vercel response streaming.
    app.get("stream") { _ in
        Response(body: try .init(stream: { writer in
            for index in 1...5 {
                try await writer.write("chunk \(index)\n")
                try await Task.sleep(for: .milliseconds(200))
            }
        }, count: nil))
    }

    app.get("error") { _ -> String in
        throw Abort(.internalServerError, reason: "Intentional error")
    }

    // Shows up under this request in Vercel's logs, with the warning level.
    app.get("log") { _ in
        logger.warning("hello from swift-log", metadata: ["route": "log"])
        return "logged\n"
    }

    // Responds immediately; the function keeps running until the background work is done.
    app.get("wait-until", ":ms") { req in
        let milliseconds = try req.parameters.require("ms", as: Int.self)
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
    app.get("cron") { _ in
        logger.info("cron job ran")
        return "cron ok\n"
    }

    app.get("geo") { req in
        let environment = VercelEnvironment.current
        let vercel = req.headers.vercel
        return RequestDetails(
            id: vercel.id,
            ipAddress: vercel.ipAddress,
            geolocation: vercel.geolocation,
            environment: environment.target?.rawValue,
            region: environment.region
        )
    }
}

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
