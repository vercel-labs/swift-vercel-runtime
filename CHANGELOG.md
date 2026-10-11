# Changelog

## Unreleased

- Git deployments: `scripts/vercel-install-swift.sh`, used as a project's Install Command, installs
  the swift.org toolchain and Static Linux SDK in Vercel's build image and keeps them (and the
  package's `.build`) in Vercel's build cache, so Vercel can run `swift package vercel` on every
  push. See "Deploy from Git" in the README.
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
