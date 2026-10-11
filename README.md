# Swift Vercel Runtime

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fvercel-labs%2Fswift-vercel-runtime%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/vercel-labs/swift-vercel-runtime)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fvercel-labs%2Fswift-vercel-runtime%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/vercel-labs/swift-vercel-runtime)

Run Swift servers natively on [Vercel](https://vercel.com). Write a normal Vapor, Hummingbird or
any other Swift HTTP server that listens on a port: no Vercel-specific code, adapters or
framework packages. It is cross-compiled with the
[Swift Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)
into a static binary that Vercel's `executable` runtime runs directly, with no Docker, streaming
responses, WebSockets and concurrent requests included.

| Product | Use it for |
| --- | --- |
| `VercelPlugin` | `swift package vercel`: builds `.vercel/output` for `vercel deploy --prebuilt` |
| `VercelRuntime` | Optional: per-request logs, `waitUntil`, request helpers (geolocation, IP, OIDC), environment |
| `VercelCache`, `VercelGlobalConfig`, `VercelFirewall`, `VercelOIDC` | Optional: Runtime Cache, Global Config, rate limiting, OIDC and AWS credentials. `Vercel` includes them all. See [Optional Vercel features](#optional-vercel-features) |
| `VercelBootstrap` | The function's entrypoint. Built and deployed by the plugin; you never import it |

## How it works

This is how Vercel runs standalone Go servers too. Each function contains your app's binary and
`VercelBootstrap`, a small SwiftNIO program that implements the Vercel functions runtime protocol
for it:

1. The bootstrap starts your app with `PORT` set, and finds the port it actually listens on (so
   apps that ignore `PORT`, like Hummingbird's default `127.0.0.1:8080`, work too).
2. It listens on its own port and proxies every request to your app: it answers Vercel's health
   checks, strips the runtime's internal headers, streams bodies in both directions and tunnels
   WebSockets.
3. It tells the runtime when each request is done, enforces `CRON_SECRET` on cron paths, forwards
   `SIGTERM` for graceful shutdown, and reports a crashed app.

Your app never needs to know it runs on Vercel. `swift run` works locally as usual.

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

Swift 6.4.0 is the tested setup, but newer Swift releases work too: install the toolchain with
swiftly and the Static Linux SDK for the same release from swift.org. The SDK must match the
toolchain exactly; the plugin checks this before building.

### 3. Install the Vercel CLI

```sh
npm i -g vercel
vercel login
```

### 4. Create an app

Any Swift server works. With Hummingbird:

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
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0"),
        // Provides `swift package vercel`. Nothing to import.
        .package(url: "https://github.com/vercel-labs/swift-vercel-runtime.git", from: "0.6.1"),
    ],
    targets: [
        .executableTarget(name: "hello", dependencies: [
            .product(name: "Hummingbird", package: "hummingbird"),
        ]),
    ]
)
```

Replace `Sources/hello/hello.swift` with a plain Hummingbird app:

```swift
import Hummingbird

let router = Router()
router.get("/") { _, _ in "Hello from Swift on Vercel" }

let app = Application(router: router)
try await app.runService()
```

Run it locally like any Hummingbird app:

```sh
swift run   # http://localhost:8080
```

### 5. Deploy

```sh
swift package --disable-sandbox vercel   # cross-compiles and writes .vercel/output
vercel link                              # once: create or pick a Vercel project
vercel deploy --prebuilt                 # preview deployment; add --prod for production
```

- The first build downloads and compiles dependencies, which takes a minute or two; later builds
  are incremental.
- The first deployment of a new project becomes its production deployment.
- New projects have [Deployment Protection](https://vercel.com/docs/deployment-protection) on, so
  preview URLs ask you to log in to Vercel. `vercel curl <url>` works with protection on.

If the build stops with a toolchain or SDK error, follow its instructions: the plugin checks your
setup before compiling.

## Deploy from Git

Vercel can also build the app itself on every push, with no Swift on your machine. Run this once
in the package and commit the files it writes (`vercel.json`, `.swift-version` and `.gitignore`):

```sh
swift package --disable-sandbox vercel init
```

It sets the project's Install and Build Commands in `vercel.json` next to `Package.swift`,
creating the file if needed. In an existing `vercel.json` only those two settings change; the
rest of the file stays exactly as it was:

```json
{
  "installCommand": "curl -fsSL https://raw.githubusercontent.com/vercel-labs/swift-vercel-runtime/0.6.1/scripts/vercel-install-swift.sh | bash",
  "buildCommand": ".vercel/bin/swift package --disable-sandbox vercel"
}
```

Build options given to `init` (such as `--product` or `--memory`) are added to the Build Command.

`init` also writes your Swift version to `.swift-version` next to `Package.swift`, unless the file
exists: the exact release for a swift.org toolchain (like `6.4.0`), or the major and minor version
for Xcode's (like `6.4`, meaning the latest 6.4.x). Snapshot toolchains get none. Commit it, so
Vercel builds with the Swift you develop with, builds are reproducible, and upgrading Swift is a
deliberate change to that file. swiftly reads the same file, so it also picks the toolchain
locally.

It also adds `.vercel` to `.gitignore` (creating it if needed) unless Git already ignores it,
including through a parent directory's `.gitignore`: the build writes `.vercel/output` there.

Then connect the repository to a Vercel project and leave its Framework Preset on "Other" (if
`Package.swift` is not at the repository root, set the project's Root Directory to its folder).

[`vercel-install-swift.sh`](scripts/vercel-install-swift.sh) installs the swift.org toolchain for
Amazon Linux 2023 (Vercel's build image) and the matching Static Linux SDK, after checking the
toolchain's signature and the SDK's checksum. It keeps both in Vercel's build cache
(`.vercel/cache` at the repository root), along with the package's `.build`:

- The first build of a project downloads about 1.4 GB, which adds about a minute, and compiles
  everything (3 to 6 minutes for the Hummingbird and Vapor examples on a standard build machine).
- Later builds restore Swift and `.build` from the cache in a few seconds and compile
  incrementally (about a minute in total for the examples).

The toolchain is the version in `SWIFT_VERSION` (an environment variable) or `.swift-version`, like
`6.4.0` or `6.4`. Without either, Vercel builds use the latest Swift release, so a new release
changes the toolchain without notice. The build cache is per Swift version, so the first build
with a new version is a cold one.

The cache is per branch, and starts from the production branch's cache. Vercel drops a cache
larger than 1.5 GB compressed (more on larger build machines). Swift takes about 700 MB of that
and the examples' `.build` 250 to 350 MB, so the script stops caching `.build` when it grows past
2000 MB on disk; set `SWIFT_VERCEL_MAX_BUILD_CACHE_MB` to change the limit. A redeploy without
the build cache (the default for `vercel redeploy`) starts from scratch.

## Vapor

Same setup, with a plain Vapor 5 app (currently beta). Vapor reads `PORT` from the environment:

```swift
// Package.swift
platforms: [.macOS("26.2")],  // required by Vapor 5
dependencies: [
    .package(url: "https://github.com/vapor/vapor.git", from: "5.0.0-beta.3"),
    // Needed until swift-http-server tags a release with its musl fix (see Known issues).
    .package(url: "https://github.com/swift-server/swift-http-server.git", revision: "09ee2e3682248532c43975b1af5938628efb7ba8"),
    .package(url: "https://github.com/vercel-labs/swift-vercel-runtime.git", from: "0.6.1"),
],
targets: [
    .executableTarget(name: "App", dependencies: [
        .product(name: "Vapor", package: "vapor"),
    ]),
]
```

```swift
import Vapor

let app = try Application()
app.get { _ in "Hello from Swift on Vercel" }
try await app.start()
```

Vapor defaults to its `development` environment, which shows error details in responses. Set
`VAPOR_ENV=production` in your Vercel project's environment variables for production.

## Other servers

Any executable that serves HTTP/1.1 on a TCP port works: other frameworks, or a server written
directly on SwiftNIO. The app should:

- listen on `127.0.0.1` (or `0.0.0.0`), ideally on the `PORT` environment variable. If it listens
  elsewhere the bootstrap finds the port anyway (and logs a note), preferring `PORT`, then the only
  listening port, then 8080 or 3000,
- start listening within 60 seconds,
- shut down on `SIGTERM`.

`Examples/HelloNIO` is such a server, written directly on SwiftNIO with no Vercel code or
dependency besides the build plugin.

## Optional Vercel features

You do not need any of these to run on Vercel: without them your app gets routing, streaming,
WebSockets, cron protection and graceful shutdown, and everything it prints reaches Vercel's logs.
Add them for Vercel features beyond that. Each is a separate product, so you only link what you use:

| Product | Import | Adds |
| --- | --- | --- |
| `VercelRuntime` | `import VercelRuntime` | Per-request logs, `waitUntil`, request helpers, deadline, environment, outbound request metrics |
| `VercelCache` | `import VercelCache` | [Runtime Cache](#runtime-cache): a regional key-value cache with TTLs and tags |
| `VercelGlobalConfig` | `import VercelGlobalConfig` | [Global Config](#global-config) reads (formerly Edge Config) |
| `VercelFirewall` | `import VercelFirewall` | [Rate limiting](#rate-limiting) with Vercel Firewall rules |
| `VercelOIDC` | `import VercelOIDC` | [OIDC](#oidc) tokens, token exchange and AWS credentials |
| `Vercel` | `import Vercel` | Everything above |

Add the products to your target, either everything or only the ones you use:

```swift
.executableTarget(name: "App", dependencies: [
    .product(name: "Hummingbird", package: "hummingbird"),
    .product(name: "Vercel", package: "swift-vercel-runtime"),
    // Or individually, for example:
    // .product(name: "VercelRuntime", package: "swift-vercel-runtime"),
    // .product(name: "VercelCache", package: "swift-vercel-runtime"),
]),
```

`VercelCache`, `VercelGlobalConfig`, `VercelFirewall` and `VercelOIDC` build on `VercelRuntime`
and make their requests with AsyncHTTPClient.

| Feature | API | Needs `Vercel.withRequest`? |
| --- | --- | --- |
| Logs attributed to their request, with levels | `VercelLogHandler` | Yes |
| Background work after the response | `Vercel.waitUntil(for: request.headers)` | No |
| | `Vercel.waitUntil { }` | Yes |
| Geolocation, IP, request id, OIDC token, deadline | `request.headers.vercel` | No |
| | `Vercel.currentRequest`, `Vercel.deadline` | Yes |
| Outbound requests in Observability (External APIs) | `Vercel.reportFetch(...)` | Yes |
| Deployment environment | `VercelEnvironment.current` | No |
| Runtime Cache | `RuntimeCache()` | Yes, or pass `headers:` |
| Global Config | `GlobalConfig.default` | No |
| Rate limiting | `Firewall.checkRateLimit(_:)` | Yes, or pass `headers:` |
| OIDC tokens and AWS credentials | `OIDC.token()`, `AWSCredentialsProvider` | Yes, or pass `headers:` |

Everything below also works locally, so the same code runs everywhere: request-bound features are
no-ops or fall back to plain behavior (the Runtime Cache to an in-memory cache, rate limit checks to
"not limited"), and Global Config and OIDC read the variables `vercel env pull` writes to
`.env.local`. Apps only connect to the bootstrap the first time they use `Vercel.withRequest` or
`Vercel.waitUntil(for:)`; until then, requests end as soon as their response is done.

### The request middleware

Most features need to know which request your code is running for. Run your handlers inside
`Vercel.withRequest`, typically from a middleware:

```swift
import VercelRuntime

// Hummingbird
struct VercelRequestMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        try await Vercel.withRequest(request.headers) { try await next(request, context) }
    }
}
router.add(middleware: VercelRequestMiddleware())

// Vapor
struct VercelRequestMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        try await Vercel.withRequest(request.headers) { try await next.respond(to: request) }
    }
}
app.middleware.use(VercelRequestMiddleware())
```

`withRequest` takes the request's `HTTPFields`, so it works the same with any framework built on
swift-http-types. Code that runs after the handler returns, like a streamed response body or a
WebSocket, runs outside the request.

### Logs

Logging works with no setup: everything your app writes to stdout and stderr, with `print` or any
swift-log backend, shows up in Vercel's logs. Those lines are not tied to a request, though, which
makes them hard to follow when one instance serves many requests at once.

To group logs by request, use `VercelLogHandler`, a swift-log backend. Inside `Vercel.withRequest`
(for example with [the request middleware](#the-request-middleware)) it sends each log to Vercel
with its level and the request it belongs to; everywhere else (startup, background tasks, local
development) it writes a line to stdout, or stderr for `error` and above. The level defaults to
`LOG_LEVEL`, or `info`.

Install it as your swift-log backend. swift-log allows this exactly once per process, at the start
of `main`:

```swift
VercelLogHandler.bootstrap()
```

If your app already calls `LoggingSystem.bootstrap` (many app templates do), do not call both:
swift-log stops the process on a second call. Add `VercelLogHandler` to your existing setup instead,
with `MultiplexLogHandler`:

```swift
LoggingSystem.bootstrap { label in
    MultiplexLogHandler([
        VercelLogHandler(label: label),
        MyServiceLogHandler(label: label),  // your existing backend, for example a log service
    ])
}
```

`VercelLogHandler` already writes to stdout outside requests, so it replaces swift-log's default
`StreamLogHandler`. Combining the two prints every line twice. Logs from code that runs after the
handler returns, like a streamed response body or a WebSocket, are not attributed.

### waitUntil

```swift
Vercel.waitUntil(for: request.headers) {
    try await analytics.track("signup")
}
```

Runs work after the response is sent, and keeps the function alive until it finishes. Inside
`Vercel.withRequest` (for example with [the request middleware](#the-request-middleware)),
`Vercel.waitUntil { ... }` works
without passing the headers. When the request approaches its maximum duration the work is
cancelled, so check `Task.isCancelled` in long loops. Logs from the work stay attributed to the
request.

### Cron jobs

Declare crons in `vercel.json` next to `Package.swift`; `swift package vercel` copies them into the
deployment:

```json
{ "crons": [{ "path": "/cron", "schedule": "0 5 * * *" }] }
```

Cron routes are ordinary routes. When the project has a `CRON_SECRET` environment variable, the
bootstrap answers `401` to requests for the cron paths that lack `Authorization: Bearer
<CRON_SECRET>`, so only Vercel can trigger them; your app does not need to check. Crons only run on
production deployments.

### Request helpers

```swift
let vercel = request.headers.vercel
vercel.geolocation   // city, country, flag, countryRegion, region, latitude, longitude, postalCode
vercel.ipAddress     // x-real-ip
vercel.id            // x-vercel-id, as shown in Vercel's logs
vercel.oidcToken     // per-request OIDC token, or VERCEL_OIDC_TOKEN
vercel.deadline      // when Vercel stops the request (x-vercel-deadline), as a Date

let environment = VercelEnvironment.current
environment.target       // .production, .preview or .development (VERCEL_ENV)
environment.url          // VERCEL_URL
environment.region       // VERCEL_REGION
environment.git.commitSHA
```

These match `geolocation`, `ipAddress` and `getEnv` from `@vercel/functions`, and work on any
`HTTPFields` (`request.headers` in Vapor 5 and Hummingbird 2). Inside `Vercel.withRequest`,
`Vercel.currentRequest` gives the same helpers for the request being handled without passing its
headers around (like `getContext().headers`), and `Vercel.deadline` is its deadline.

### Deadline

```swift
// Skip optional work when Vercel stops the request in less than 5 seconds.
if let deadline = Vercel.deadline, deadline.timeIntervalSinceNow < 5 {
    return partialResults
}
```

`Vercel.deadline` (or `request.headers.vercel.deadline` outside `Vercel.withRequest`) is when
Vercel stops the request, at the function's maximum duration. The bootstrap passes it to your app
as `x-vercel-deadline`, replacing any value a client sent. It is `nil` locally.

### Outbound request metrics

Requests made by `VercelCache`, `VercelGlobalConfig`, `VercelFirewall` and `VercelOIDC` show up
under External APIs in Vercel's Observability automatically. Report your own requests with
`Vercel.reportFetch`:

```swift
let clock = ContinuousClock()
let started = clock.now
let response = try await client.execute(request)
Vercel.reportFetch(
    method: "GET", host: "api.example.com", path: "/v1/users", query: "page=2",
    statusCode: Int(response.status.code), duration: clock.now - started
)
```

The request is attributed to the current request. Call it inside `Vercel.withRequest`; elsewhere,
and locally, it does nothing. The feature modules' requests are also reported when you pass the
request's `headers:` explicitly instead.

### Runtime Cache

```swift
import VercelCache

struct Product: Codable { var id: String; var name: String; var price: Int }

let cache = RuntimeCache(namespace: "products")

func product(id: String) async throws -> Product {
    if let cached = try? await cache.get(id, as: Product.self) {
        return cached
    }
    let product = try await database.product(id: id)
    try? await cache.set(id, product, ttl: .seconds(300), tags: ["products"])
    return product
}

// After the catalog changes:
try await cache.expireTag("products")
```

The Runtime Cache is a key-value cache shared by every instance of your function in a region, with
TTLs and tag invalidation, like `getCache()` from `@vercel/functions`. Values are any `Codable`
type, stored as JSON, and keys are hashed the same way as in Node, so Swift and Node functions using
the same keys and namespace share entries. Dates are stored like Node's `JSON.stringify` writes them
(`2026-10-11T17:00:00.123Z`, millisecond precision) and read with or without fractional seconds;
pass `encoder:` and `decoder:` (start from `RuntimeCache.defaultEncoder` and `defaultDecoder` to
keep that) to change how values are encoded.

Vercel tells each request where the cache is, so use it inside `Vercel.withRequest` or pass
`RuntimeCache(headers: request.headers)`. Locally, and outside a request, it uses an in-memory
cache with the same behavior and logs a warning once. Unlike Node, which logs failures and returns
`null`, operations throw `RuntimeCacheError` when the cache fails or takes longer than 500 ms (set
`RUNTIME_CACHE_TIMEOUT` in milliseconds to change it); use `try?` as above so an outage does not
fail the request.

### Global Config

```swift
import VercelGlobalConfig

let config = try GlobalConfig.default

// A feature flag.
if try await config.get("newCheckout", as: Bool.self) == true {
    // ...
}

// A redirect map stored as {"redirects": {"/old": "/new"}}.
let redirects = try await config.get("redirects", as: [String: String].self) ?? [:]

// Several items at once, decoded into your own type, or untyped as [String: GlobalConfigValue].
struct Flags: Decodable { var newCheckout: Bool?; var maintenance: Bool? }
let flags = try await config.getAll(keys: ["newCheckout", "maintenance"], as: Flags.self)
```

[Global Config](https://vercel.com/docs/global-config) (formerly Edge Config) is a global store
for feature flags, redirects and other configuration that changes without a redeploy. Connect a
store to the project and Vercel sets `EDGE_CONFIG`, which `GlobalConfig.default` reads; use
`GlobalConfig(connectionString:)` for other stores. `has(_:)` and `digest()` work like in
`@vercel/edge-config`, and `consistentRead: true` reads the latest value, skipping caches.

Vercel currently provides local, sub-millisecond reads only to Node.js and Bun functions, so reads
from Swift go to the store's HTTP API, which takes a network round trip. If Vercel ships a snapshot
of the store to the function, reads use it automatically.

### Rate limiting

```swift
import VercelFirewall

// Hummingbird
router.post("login") { request, _ -> Response in
    let result = try await Firewall.checkRateLimit("login", headers: request.headers)
    if result.rateLimited {
        return Response(status: .tooManyRequests)
    }
    // ...
}
```

Rate limits are rules in the Vercel Firewall, like `checkRateLimit` from `@vercel/firewall`. For
each limit, open the project's Firewall tab in the Vercel dashboard, add a custom rule with the
@vercel/firewall (Rate limit API ID) condition and an ID such as `login`, choose the Rate Limit
action with its window and number of requests, and publish it. Use the same ID in code.

The limit applies per client IP (`x-real-ip`) unless you pass `rateLimitKey:`, for example a user
ID. An ID without a rule is not limited and `result.reason` is `.notFound`; a request the rule
blocks is limited with `.blocked`. `headers:` can be omitted inside `Vercel.withRequest`. When not running
on Vercel, checks log a warning once and return "not limited", unless you pass
`firewallHostForDevelopment: "my-app.vercel.app"` to check that deployment's rules. Set
`RATE_LIMIT_SECRET` to mix a secret into the hashed key, and `VERCEL_AUTOMATION_BYPASS_SECRET` if
the deployment uses Deployment Protection.

### OIDC

```swift
import VercelOIDC

// The request's OIDC token, for services that trust Vercel's OIDC issuer.
let token = try OIDC.token()
let claims = try VercelOIDCToken(token)
print(claims.projectID ?? "-", claims.environment ?? "-", claims.expiresAt ?? "-")

// A Vercel-issued token for another audience (cached until it expires).
let apiToken = try await OIDC.exchange(audience: "https://api.example.com")

// Temporary AWS credentials, cached and refreshed before they expire. Create one provider per role.
let aws = AWSCredentialsProvider(roleARN: "arn:aws:iam::123456789012:role/my-app", region: "us-east-1")
let credentials = try await aws.credentials()
// credentials.accessKeyID, credentials.secretAccessKey, credentials.sessionToken
```

With OIDC enabled in the project settings, Vercel sends a short-lived token with every request
(`x-vercel-oidc-token`); `OIDC.token()` reads it from the current request, else from
`VERCEL_OIDC_TOKEN`, which `vercel env pull` writes for local development (pull again when it
expires, after about 12 hours). Do not store the token. `AWSCredentialsProvider` calls STS
`AssumeRoleWithWebIdentity` with it, like `awsCredentialsProvider` from `@vercel/functions/oidc`;
the role's trust policy must allow Vercel's OIDC provider. Its documentation shows how to plug it
into Soto. `OIDC.awsCredentials(roleARN:)` gets new credentials on every call. Printing or
`dump`ing credentials, tokens, `GlobalConfig` or `RuntimeCache` never shows secrets.

## WebSockets

Vercel tunnels WebSocket connections to functions on Fluid Compute, and the bootstrap passes them
through to your app. Serve them however your framework does; with Hummingbird and
hummingbird-websocket:

```swift
let webSocketRouter = Router(context: BasicWebSocketRequestContext.self)
webSocketRouter.ws("ws") { inbound, outbound, _ in
    for try await message in inbound.messages(maxSize: 1 << 16) {
        if case .text(let text) = message {
            try await outbound.write(.text(text))
        }
    }
}

let app = Application(router: router, server: .http1WebSocketUpgrade(webSocketRouter: webSocketRouter))
```

The request ends as soon as the upgrade is answered, and the platform then keeps the connection open
in both directions; this is how Vercel's Node.js, Python, Rust and Go runtimes work too. So code
inside a WebSocket handler runs outside the request: its logs are not attributed to it, and
`waitUntil` work started there is not waited for.

Vapor 5 does not support WebSockets yet (they are disabled in the 5.0 betas).

## Build options

```sh
swift package --disable-sandbox vercel
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
| `--swift-sdks-path <path>` | `$SWIFT_VERCEL_SDKS_PATH`, then SwiftPM's | Directory with installed Swift SDKs |
| `--configuration <cfg>` | `release` | `release` or `debug` |
| `--output <path>` | `.vercel/output` | Build Output API directory |
| `--static-dir <path>` | | Serve a directory (for example `Public`) from Vercel's CDN |
| `--memory <mb>`, `--max-duration <s>`, `--region <id>` | Vercel defaults | Function settings |
| `--no-strip` | | Keep debug symbols |

The output follows the [Build Output API](https://vercel.com/docs/build-output-api/v3): one
function (`functions/index.func`) with `"runtime": "executable"` whose handler, `executable`, is
the bootstrap, with your app's binary next to it, plus a route that sends every path to it. SwiftPM resource bundles
are copied next to the binaries, and `crons` are taken from `vercel.json` for prebuilt deployments
(inside `vercel build`, as in a Git deployment, Vercel adds them itself). Other `vercel.json`
settings, apart from the build settings Vercel applies itself, are not applied to the output.

## The bootstrap in detail

On Vercel the bootstrap is started with `VERCEL_IPC_PATH` set. It:

1. connects to the runtime's Unix socket,
2. starts the app with the project's environment, minus `VERCEL_IPC_PATH`, plus `PORT` and
   `VERCEL_BOOTSTRAP_SOCKET`,
3. waits until the app listens (read from `/proc` on Linux), listens on `127.0.0.1:0` and sends
   `server-started` with that port,
4. for each request: answers `GET /_vercel/ping` itself; removes `x-vercel-internal-*` headers
   (exposing the OIDC token as `x-vercel-oidc-token` and the deadline as `x-vercel-deadline`,
   replacing any sent by a client) and the runtime cache headers (keeping hidden ones for the app to
   ask for over its socket); adds an opaque
   `x-vercel-bootstrap-request` token (replacing any sent by a client); proxies the request on a
   dedicated connection to the app; and sends `end` once the response is complete, or right after
   a `101 Switching Protocols`,
5. on `SIGTERM`, forwards it to the app and exits with it. If the app exits on its own, it reports
   an `unrecoverable-error` and exits.

Apps that use `VercelRuntime` connect to `VERCEL_BOOTSTRAP_SOCKET`. The bootstrap then forwards
their request-attributed logs and fetch metrics, answers their requests for hidden runtime cache
configuration, and holds each request's `end` until the app reports its `waitUntil`
work done (or it is cancelled by `approaching-timeout`). Apps that never connect pay nothing for it.

## Development

```sh
swift test                  # unit tests, including the proxy against a real NIO server
scripts/test-plugin.sh      # the plugin's vercel.json edits, .swift-version and toolchain check
scripts/test-linux.sh       # build every example with the plugin and run the contract
                            # tests against the Linux binaries
```

The binaries are fully static, so on Linux `test-linux.sh` runs them directly; on macOS it runs
them in an `amazonlinux:2023` container (Docker). CI runs all three on a Linux arm64 runner
(`.github/workflows/ci.yml`) with Swift 6.4 and the latest Swift release, on every push and daily;
`scripts/install-static-sdk.sh` installs the Static Linux SDK matching the toolchain there.

`scripts/fake-runtime.py` emulates Vercel's runtime: it spawns the function's handler the same way,
decodes messages with the same strict schema, sends `approaching-timeout`, and checks ping handling,
the app's environment, header stripping (including runtime cache headers), `end` messages for
success/404/500/streaming/concurrent requests, per-request logs and fetch metrics (none after their
request's `end`), `waitUntil` timing and cancellation, cron authorization, request helpers,
graceful shutdown, and that a crashing app is reported. Examples with WebSocket routes also get
WebSocket checks: `end` at accept while the socket stays open, text and binary echo, declined
upgrades, and concurrent connections. The Hummingbird example listens on its default port, which
checks port discovery, and also serves routes for the feature modules (`/cache/:key`,
`/global-config`, `/rate-limit/:id`, `/oidc`) that answer JSON describing what happened, for
end-to-end tests on a deployment; the harness smoke-tests OIDC claims through them. The Vapor
example uses `VercelCache` only, which keeps the check that it links no ICU meaningful for the
feature modules. For both, the harness checks the Runtime Cache routes against its in-memory
fallback and against a stub of Vercel's cache service, passed as `x-vercel-sc-*` headers that are
either visible to the app or hidden by the bootstrap. The SwiftNIO example has no Vercel code at
all (the harness skips the optional-feature checks for it).

## Known issues

- Vapor 5.0.0-beta.3 resolves swift-http-server 0.3.0, which does not compile with the Static
  Linux SDK ([swiftlang/swift#92476](https://github.com/swiftlang/swift/issues/92476)). Apps pin
  swift-http-server to 0.3.0 plus its upstream fix until a release includes it. SwiftPM only allows
  revision pins in the root package, so the pin cannot live in this library.
- Hummingbird links full Foundation, which includes ICU data: its binaries are about 62 MB versus
  about 29 MB for Vapor 5.
- After either side closes a WebSocket, clients see the close about 10 seconds later. Vercel's own
  Rust WebSocket example shows the same delay, so it comes from the platform.

## License

Apache 2.0. See [LICENSE](LICENSE).
