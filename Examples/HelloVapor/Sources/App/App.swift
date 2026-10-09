import Logging
import Vapor
import VercelVapor

@main
struct App {
    static func main() async throws {
        // Attributes logs to the request that produced them in Vercel's logs.
        VercelLogHandler.bootstrap()

        let app = try Application.vercel()
        try routes(app)
        try await app.start()
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

    // Scheduled from vercel.json. Requires `Authorization: Bearer $CRON_SECRET` when set.
    app.grouped(VercelCronMiddleware()).get("cron") { _ in
        logger.info("cron job ran")
        return "cron ok\n"
    }

    app.get("geo") { req in
        let environment = VercelEnvironment.current
        return RequestDetails(
            id: req.vercel.id,
            ipAddress: req.vercel.ipAddress,
            geolocation: req.vercel.geolocation,
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
