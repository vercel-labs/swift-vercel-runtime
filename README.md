# Swift Vercel Runtime

Run Swift servers natively on [Vercel](https://vercel.com). Your app is cross-compiled with the
[Swift Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)
into a single static binary that Vercel's `executable` runtime runs directly: no Docker, no proxy,
streaming responses and concurrent requests included.

| Product | Use it for |
| --- | --- |
| `VercelHummingbird` | [Hummingbird 2](https://github.com/hummingbird-project/hummingbird) apps |
| `VercelHummingbirdWebSocket` | WebSockets for Hummingbird apps, with [hummingbird-websocket](https://github.com/hummingbird-project/hummingbird-websocket) |
| `VercelVapor` | [Vapor 5](https://github.com/vapor/vapor) apps (currently beta) |
| `VercelRuntime` | The runtime protocol itself, for any other Swift HTTP server |
| `VercelBuildPlugin` | `swift package vercel-build`: builds `.vercel/output` for `vercel deploy --prebuilt` |

SwiftPM only resolves the framework behind the adapter you use.

## Getting started

You need a Mac (or Linux machine) with the swift.org Swift 6.4 toolchain, the matching Static Linux
SDK, and the Vercel CLI. This takes a few minutes once.

### 1. Install the swift.org toolchain

The Static Linux SDK only works with the swift.org toolchain, not the one in Xcode. Install it with
[swiftly](https://www.swift.org/install/macos/) (Xcode keeps working for Apple platforms):

```sh
curl -O https://download.swift.org/swiftly/darwin/swiftly.pkg && \
  installer -pkg swiftly.pkg -target CurrentUserHomeDirectory && \
  ~/.swiftly/bin/swiftly init --quiet-shell-followup && \
  . "${SWIFTLY_HOME_DIR:-$HOME/.swiftly}/env.sh" && hash -r
swiftly install 6.4.0 && swiftly use 6.4.0
```

`swift --version` should now print `(swift-6.4-RELEASE)`. If it prints `(swiftlang-...)` you are
still on Apple's toolchain; open a new shell.

### 2. Install the Static Linux SDK

```sh
swift sdk install https://download.swift.org/swift-6.4.0-release/static-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
  --checksum 47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e
```

`swift sdk list` should show `swift-6.4.0-RELEASE_static-linux-0.1.0`. For other Swift versions, use
the command under "Swift SDK for Static Linux" on [swift.org/install](https://www.swift.org/install/macos/).

### 3. Install the Vercel CLI

```sh
npm i -g vercel
vercel login
```

### 4. Create an app

```sh
mkdir hello && cd hello
swift package init --type executable --name hello
```

Replace `Package.swift`:

```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "hello",
    platforms: [.macOS("26.2")],
    dependencies: [
        .package(url: "https://github.com/vercel-labs/swift-vercel-runtime.git", from: "0.1.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0"),
    ],
    targets: [
        .executableTarget(name: "hello", dependencies: [
            .product(name: "VercelHummingbird", package: "swift-vercel-runtime"),
            .product(name: "Hummingbird", package: "hummingbird"),
        ]),
    ]
)
```

The `platforms` line is required: this package needs macOS 26.2 (because Vapor 5 does), and new
packages default to an older version.

Replace `Sources/hello/hello.swift`:

```swift
import Hummingbird
import VercelHummingbird

let router = Router()
router.get("/") { _, _ in "Hello from Swift on Vercel" }

let app = Application(vercel: router)  // same arguments as Application(router:)
try await app.runService()
```

Run it locally like any Hummingbird app:

```sh
swift run   # http://localhost:8080
```

### 5. Deploy

```sh
swift package --disable-sandbox vercel-build   # cross-compiles and writes .vercel/output
vercel link                                    # once: create or pick a Vercel project
vercel deploy --prebuilt                       # preview deployment; add --prod for production
```

- The first build downloads and compiles dependencies, which takes a minute or two; later builds
  are incremental.
- The first deployment of a new project becomes its production deployment.
- New projects have [Deployment Protection](https://vercel.com/docs/deployment-protection) on, so
  preview URLs ask you to log in to Vercel. `vercel curl <url>` works with protection on.

If the build stops with a toolchain or SDK error, follow its instructions: the plugin checks your
setup before compiling.

## Vapor

Same setup as above, with these dependencies:

```swift
// Package.swift
platforms: [.macOS("26.2")],
dependencies: [
    .package(url: "https://github.com/vercel-labs/swift-vercel-runtime.git", from: "0.1.0"),
    .package(url: "https://github.com/vapor/vapor.git", from: "5.0.0-beta.3"),
    // Needed until swift-http-server tags a release with its musl fix (see Known issues).
    .package(url: "https://github.com/swift-server/swift-http-server.git", revision: "09ee2e3682248532c43975b1af5938628efb7ba8"),
],
targets: [
    .executableTarget(name: "App", dependencies: [
        .product(name: "VercelVapor", package: "swift-vercel-runtime"),
        .product(name: "Vapor", package: "vapor"),
    ]),
]
```

```swift
import Vapor
import VercelVapor

let app = try Application.vercel()  // same arguments as Application(...)
app.get { _ in "Hello from Swift on Vercel" }
try await app.start()
```

Locally (outside Vercel) both behave like regular Hummingbird and Vapor apps, so `swift run` works
as usual.

## Vercel features

The adapters re-export `VercelRuntime`, so everything below is available with a single import.

### Logs

```swift
VercelLogHandler.bootstrap()  // once, at the start of main
```

A swift-log backend. Inside a request, every log is sent to Vercel with its level and attributed to
that request, even with many concurrent requests (the same mechanism the Node.js and Python runtimes
use). Outside a request it writes a line to stdout (stderr for `error` and above). The level
defaults to `LOG_LEVEL`, or `info`. `print` still goes to stdout without attribution, so prefer
swift-log.

### waitUntil

```swift
Vercel.waitUntil {
    try await analytics.track("signup")
}
```

Runs work after the response is sent, and keeps the function alive until it finishes. When the
request approaches its maximum duration the work is cancelled, so check `Task.isCancelled` in long
loops. Logs from the work stay attributed to the request.

### Cron jobs

Declare crons in `vercel.json` next to `Package.swift`; `vercel-build` copies them into the
deployment:

```json
{ "crons": [{ "path": "/cron", "schedule": "0 5 * * *" }] }
```

Protect the route so only Vercel can call it when the project has a `CRON_SECRET`:

```swift
// Vapor
app.grouped(VercelCronMiddleware()).get("cron") { _ in "ok" }
// Hummingbird
router.group("cron").add(middleware: VercelCronMiddleware()).get { _, _ in "ok" }
```

Without `CRON_SECRET` every request is allowed, matching Vercel's Python runtime. Crons only run on
production deployments.

### Request helpers

```swift
req.vercel.geolocation   // city, country, flag, countryRegion, region, latitude, longitude, postalCode
req.vercel.ipAddress     // x-real-ip
req.vercel.id            // x-vercel-id, as shown in Vercel's logs
req.vercel.oidcToken     // per-request OIDC token, or VERCEL_OIDC_TOKEN

let environment = VercelEnvironment.current
environment.target       // .production, .preview or .development (VERCEL_ENV)
environment.url          // VERCEL_URL
environment.region       // VERCEL_REGION
environment.git.commitSHA
```

These match `geolocation`, `ipAddress` and `getEnv` from `@vercel/functions`. On any `HTTPFields`
they are available as `headers.vercel`.

### WebSockets

Vercel tunnels WebSocket connections to functions on Fluid Compute. With Hummingbird, add
`VercelHummingbirdWebSocket` and serve with `.vercelWebSocketUpgrade` instead of
`.http1WebSocketUpgrade`:

```swift
import HummingbirdWebSocket
import VercelHummingbirdWebSocket

let webSocketRouter = Router(context: BasicWebSocketRequestContext.self)
webSocketRouter.ws("ws") { inbound, outbound, _ in
    for try await message in inbound.messages(maxSize: 1 << 16) {
        if case .text(let text) = message {
            try await outbound.write(.text(text))
        }
    }
}

let app = Application(vercel: router, server: .vercelWebSocketUpgrade(webSocketRouter: webSocketRouter))
```

The closure form, `.vercelWebSocketUpgrade { head, channel, logger in ... }`, is also available.

The invocation ends as soon as the upgrade is accepted (or declined), and the platform then keeps
the connection open in both directions; this is how Vercel's Node.js, Python, Rust and Go runtimes
work too. So code inside a WebSocket handler runs outside the request: its logs go to stdout
without request attribution, and `Vercel.waitUntil` work started there runs as a plain task that
the platform does not wait for.

Vapor 5 does not support WebSockets yet (they are disabled in the 5.0 betas, and swift-http-server
has no HTTP/1.1 upgrade support).

## Build options

```sh
swift package --disable-sandbox vercel-build
vercel deploy --prebuilt
```

Use `--disable-sandbox`: the plugin runs a nested `swift build` with the Static Linux SDK, which
needs the SwiftPM caches and network access that the plugin sandbox blocks (same as `lambda-build`
in swift-aws-lambda-runtime). Its build files go to `.build/vercel`.

| Option | Default | |
| --- | --- | --- |
| `--product <name>` | the only executable | Executable product to deploy |
| `--architecture <arch>` | `arm64` | `arm64` or `x86_64` |
| `--swift-sdk <id>` | Static Linux SDK for the architecture | Any installed Swift SDK |
| `--configuration <cfg>` | `release` | `release` or `debug` |
| `--output <path>` | `.vercel/output` | Build Output API directory |
| `--static-dir <path>` | | Serve a directory (for example `Public`) from Vercel's CDN |
| `--memory <mb>`, `--max-duration <s>`, `--region <id>` | Vercel defaults | Function settings |
| `--no-strip` | | Keep debug symbols |

The output follows the [Build Output API](https://vercel.com/docs/build-output-api/v3): one
function (`functions/index.func`) with `"runtime": "executable"`, plus a route that sends every
path to it. SwiftPM resource bundles are copied next to the binary, and `crons` are taken from
`vercel.json` (other `vercel.json` settings are not applied to prebuilt deployments).

## Other Swift servers

Any server can run on Vercel with `VercelRuntime`. On Vercel the process is started with
`VERCEL_IPC_PATH` set, and it must:

1. listen on `127.0.0.1` (any port, `0` is fine) and report the port once listening,
2. answer `GET /_vercel/ping` with `200` without sending anything,
3. strip the runtime's internal request headers,
4. report every finished request, including errors.
5. for WebSocket (HTTP/1.1 `Upgrade`) requests, report the request finished as soon as it answers
   the upgrade, not when the socket closes.

```swift
import VercelRuntime

let runtime = VercelRuntime.shared  // connects to VERCEL_IPC_PATH; no-op locally

// 1. once the server is listening
runtime.serverStarted(httpPort: port)

// 2-4. per request
if path == VercelHeader.pingPath { return ok("OK") }
var headers: HTTPFields = request.headers
let invocation = headers.removeVercelInternalFields()
return try await runtime.withRequest(invocation) {
    try await handle(request.with(headers))
}
```

`withRequest` sends `end` once the handler and its `waitUntil` work are done, attributes
`VercelLogHandler` logs to the request, and handles `approaching-timeout`.

See `Sources/VercelHummingbird` for a complete adapter in about 60 lines.

## Development

```sh
swift test                  # unit tests
scripts/test-linux.sh       # build every example with the plugin and run the contract
                            # tests against the Linux binary
```

The binaries are fully static, so on Linux `test-linux.sh` runs them directly; on macOS it runs
them in an `amazonlinux:2023` container (Docker). CI runs both commands on a Linux arm64 runner
(`.github/workflows/ci.yml`).

`scripts/fake-runtime.py` emulates Vercel's runtime: it spawns the binary the same way, decodes
messages with the same strict schema, sends `approaching-timeout`, and checks ping handling,
header stripping (including runtime cache headers), `end` messages for success/404/500/streaming/
concurrent requests, per-request logs, `waitUntil` timing and cancellation, cron authorization,
request helpers, and graceful shutdown. Examples that use `VercelHummingbirdWebSocket` also get
WebSocket checks: `end` at accept while the socket stays open, text and binary echo, declined
upgrades, and concurrent connections.

## Known issues

- Vapor 5.0.0-beta.3 resolves swift-http-server 0.3.0, which does not compile with the Static
  Linux SDK ([swiftlang/swift#92476](https://github.com/swiftlang/swift/issues/92476)). Apps pin
  swift-http-server to 0.3.0 plus its upstream fix until a release includes it. SwiftPM only allows
  revision pins in the root package, so the pin cannot live in this library.
- Hummingbird links full Foundation, which includes ICU data: its binaries are about 62 MB versus
  about 29 MB for Vapor 5.
- The package requires macOS 26.2 because Vapor 5 does.
- After either side closes a WebSocket, clients see the close about 10 seconds later. Vercel's own
  Rust WebSocket example shows the same delay, so it comes from the platform.

## License

Apache 2.0. See [LICENSE](LICENSE).
