# Changelog

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
