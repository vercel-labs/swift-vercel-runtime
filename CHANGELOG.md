# Changelog

## 0.6.1

- `swift package --disable-sandbox vercel init` adds `.vercel` to `.gitignore` (creating it if
  needed) unless Git already ignores it, including through a parent directory's `.gitignore`.
  The build writes `.vercel/output` there. A `.vercel` ignored only by your global Git excludes
  file still gets added, since it wouldn't be ignored in other clones.

## 0.6.0

- `swift package --disable-sandbox vercel init` also writes the local Swift version to
  `.swift-version` (unless the file exists): the exact release for a swift.org toolchain (like
  `6.4.0`), major.minor for Xcode's (like `6.4`), none for snapshots. Vercel builds then use the
  Swift you develop with, and new Swift releases are opt-in. swiftly reads the same file.
- `vercel-install-swift.sh`: `.swift-version` and `SWIFT_VERSION` match swift.org releases
  however they are named, so `6.3.0` finds the release named `6.3`.
- Toolchain check: no hardcoded Swift versions. For Apple's toolchain it suggests
  `swiftly install`/`swiftly use` with its major.minor version (or `latest`); for a missing or
  mismatched Static Linux SDK it points to swift.org's `swift sdk install` command instead of
  guessing a URL. An SDK named without a patch version (like `swift-6.3-RELEASE_static-linux-0.1.0`)
  now matches its toolchain.
- CI tests Swift 6.4 and the latest Swift release, also daily, and installs the matching Static
  Linux SDK with the new `scripts/install-static-sdk.sh`.
- `scripts/test-plugin.sh` (replacing `scripts/test-vercel-json.sh`) tests all of the plugin's
  PackagePlugin-free logic, with the tests in `scripts/plugin-tests`.

## 0.5.0

New optional products for Vercel features, each its own library so apps only link what they use.
See "Optional Vercel features" in the README.

- `VercelCache`: the Vercel Runtime Cache (`RuntimeCache`), like `getCache()` from
  `@vercel/functions` and sharing entries with it: `Codable` values with TTLs and tags (dates
  encoded like Node's `JSON.stringify`, customizable with `encoder:`/`decoder:`), and an in-memory
  fallback locally.
- `VercelGlobalConfig`: reads Global Config (formerly Edge Config) stores (`GlobalConfig`), like
  `@vercel/edge-config`: `get`, `has`, `getAll` and `digest`, typed or as `GlobalConfigValue`.
- `VercelFirewall`: rate limiting with Vercel Firewall rules (`Firewall.checkRateLimit`, returning
  a `RateLimitResult` with an optional `RateLimitResult.Reason`), like `@vercel/firewall`.
- `VercelOIDC`: the request's OIDC token and its claims (`OIDC.token()`, `VercelOIDCToken`), token
  exchange for other audiences (`OIDC.exchange`), and AWS credentials from STS
  (`AWSCredentialsProvider`, `OIDC.awsCredentials`).
- Each feature module throws its own error type (`RuntimeCacheError`, `GlobalConfigError`,
  `VercelFirewallError`, `VercelOIDCError`) with `timedOut`, `requestFailed` and an unexpected
  status case. Descriptions, `dump` and debug output of credentials, tokens and clients never
  show secrets.
- `Vercel`: everything above plus `VercelRuntime`, with one `import Vercel`.
- `VercelRuntime`: `Vercel.withRequest` now also works locally and sets `Vercel.currentRequest`,
  which the feature modules use to find the request's headers. `Vercel.deadline` and
  `request.headers.vercel.deadline` give the request's deadline. `Vercel.reportFetch` shows
  outbound requests under External APIs in Observability; the feature modules report theirs
  automatically.
- `VercelBootstrap`: passes the request deadline to the app as `x-vercel-deadline` (replacing any
  sent by a client), forwards fetch metrics, and hands runtime cache configuration that Vercel
  hides from request headers to the app over its socket (asked once per request, with a 1 second
  timeout). It no longer depends on `VercelRuntime`, so it stays small.

## 0.4.0

- Git deployments: `scripts/vercel-install-swift.sh`, used as a project's Install Command, installs
  the swift.org toolchain and Static Linux SDK in Vercel's build image and keeps them (and the
  package's `.build`) in Vercel's build cache, so Vercel can run `swift package vercel` on every
  push. See "Deploy from Git" in the README.
- `swift package --disable-sandbox vercel init [build options]` sets up Git deployments: it sets
  `installCommand` and `buildCommand` in `vercel.json`, creating the file if needed. In an
  existing `vercel.json` nothing else changes, not even formatting or key order.
- `swift package vercel --swift-sdks-path <path>` (or `SWIFT_VERCEL_SDKS_PATH`) builds with SDKs
  from another directory.
- `vercel.json` build settings (`installCommand`, `buildCommand`, ...) no longer print an
  "ignoring" note.
- Inside `vercel build` (`VERCEL=1`), `crons` are no longer copied into `config.json`: Vercel adds
  them from `vercel.json` itself and rejected the duplicates.

## 0.3.0

### Breaking changes

- The build command is now `swift package --disable-sandbox vercel` (was `vercel-build`). Options
  are unchanged.
- The plugin product and target are now `VercelPlugin` (were `VercelBuildPlugin`). Apps do not
  reference plugin products, so only scripts that invoke the command change.

## 0.2.0

Any Swift server that listens on a port now runs on Vercel unchanged, with no framework adapters.
This is how Vercel runs standalone Go servers.

- `VercelBootstrap` (new): the function's entrypoint. It starts your app with `PORT` set, finds
  the port it listens on (from `/proc`, so apps that ignore `PORT` work too), and proxies requests
  to it. It also implements the Vercel runtime protocol for the app: health checks, internal
  header stripping, an `end` per request (and at `101` for WebSockets), streaming in both
  directions with backpressure, WebSocket tunnels, `CRON_SECRET` enforcement on cron paths,
  `SIGTERM` forwarding, and crash reporting. Built and deployed by `vercel-build`.
- `VercelBuildPlugin`: builds both binaries and writes `vercel-bootstrap.json`; the function's
  handler, `executable`, is now the bootstrap, like Vercel's Go builder. Executable products named
  `executable` or `bootstrap` are rejected (AWS Lambda would run a file named `bootstrap` as its
  runtime, bypassing Vercel's).
- `VercelRuntime` is now optional and framework-agnostic. Per-request logs and `waitUntil` take the
  request's `HTTPFields`: `Vercel.withRequest(request.headers) { ... }` (typically from a
  five-line middleware) and `Vercel.waitUntil(for: request.headers) { ... }`. They talk to the
  bootstrap over `VERCEL_BOOTSTRAP_SOCKET`, connecting on first use. Request helpers are
  `request.headers.vercel`.
- The package now requires macOS 15 instead of macOS 26.2 (Vapor 5 still requires macOS 26.2).

### Breaking changes

- Removed `VercelVapor`, `VercelHummingbird` and `VercelHummingbirdWebSocket`. Use
  `Application()` / `Application(router:)` and `.http1WebSocketUpgrade` directly.
- Removed `VercelCronMiddleware`: the bootstrap enforces `CRON_SECRET` on the cron paths from
  `vercel.json`. `VercelCron.isAuthorized(_:secret:)` remains for other routes.
- Removed the in-process runtime API (`VercelRuntime` class, `serverStarted`, `withRequest(_:)`
  with an `InvocationContext`, `removeVercelInternalFields`): the bootstrap owns the runtime
  protocol now.
- `request.vercel` is now `request.headers.vercel`.

## 0.1.0

First release. Run Swift servers natively on Vercel: apps are cross-compiled with the Swift Static
Linux SDK into a static binary that Vercel's `executable` runtime runs directly.

- `VercelRuntime`: the Vercel functions runtime protocol over SwiftNIO (non-blocking IPC with a
  single writer and bounded log buffering), request lifecycle with `withRequest`, header handling,
  `VercelLogHandler` (per-request logs for swift-log), `Vercel.waitUntil`, request helpers
  (geolocation, IP address, request id, OIDC token), `VercelEnvironment`, and cron authorization.
- `VercelHummingbird`: `Application(vercel:)` and `VercelCronMiddleware` for Hummingbird 2.
- `VercelHummingbirdWebSocket`: `.vercelWebSocketUpgrade` for WebSockets with hummingbird-websocket.
- `VercelVapor`: `Application.vercel()` and `VercelCronMiddleware` for Vapor 5 (beta).
- `VercelBuildPlugin`: `swift package --disable-sandbox vercel-build` writes Build Output API v3
  for `vercel deploy --prebuilt`, with crons from `vercel.json`, static files, function settings,
  and a toolchain/SDK check before compiling.
