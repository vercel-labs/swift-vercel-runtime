# AGENTS.md

How to work in this repository. Read `README.md` for what the package does for users; this file is
about how it is built, what must not break, and how to verify changes.

## What this is

Swift servers run on Vercel's native `executable` runtime as fully static Linux binaries:

1. `swift package --disable-sandbox vercel` (the `VercelPlugin` command plugin) cross-compiles the
   app and `VercelBootstrap` with the Swift Static Linux SDK and writes `.vercel/output` (Build
   Output API v3).
2. On Vercel, `VercelBootstrap` is the function's handler (`executable`). It starts the app, finds
   its port, proxies every request to it, and speaks Vercel's runtime IPC protocol on its behalf.
3. Apps may use the optional libraries (`VercelRuntime`, `VercelCache`, `VercelGlobalConfig`,
   `VercelFirewall`, `VercelOIDC`, or the `Vercel` umbrella), which talk to the bootstrap over a
   Unix socket and to Vercel services over HTTP.

Deployments are either prebuilt (`vercel deploy --prebuilt`) or built by Vercel from Git with
`scripts/vercel-install-swift.sh` as the Install Command (`swift package vercel init` sets it up).

## Layout

| Target | Kind | Depends on | Notes |
| --- | --- | --- | --- |
| `VercelProtocol` | internal | HTTPTypes, NIO | Everything the bootstrap and runtime share: IPC messages, bootstrap socket protocol, header rules, small helpers |
| `VercelBootstrap`, `VercelBootstrapCore` | executable | `VercelProtocol`, NIO | Ships in every function. Proxy, request tracker, app socket |
| `VercelRuntime` | library | `VercelProtocol`, Logging, NIO | Public: `Vercel` (withRequest, waitUntil, currentRequest, deadline, reportFetch), request helpers, env, cron, log handler |
| `VercelHTTP` | internal | `VercelRuntime`, AsyncHTTPClient | The only place HTTP happens: transport, fetch metrics, SHA-256, URL encoding, `MockHTTPTransport` |
| `VercelCache`, `VercelGlobalConfig`, `VercelFirewall`, `VercelOIDC` | libraries | `VercelRuntime`, `VercelHTTP` | One Vercel feature each |
| `Vercel` | library | all public libraries | `@_exported import` only |
| `VercelPlugin` | plugin | none | `Plugin.swift` plus PackagePlugin-free logic files |

`Examples/` (HelloHummingbird, HelloVapor, HelloNIO) depend on this checkout by path (`../..`) and
double as the contract harness's test apps. `scripts/` has the test tooling and the install script.

## Invariants (do not break)

### Bootstrap size and dependencies
- The bootstrap depends only on `VercelProtocol` (+ NIO, HTTPTypes). Never make it depend on
  `VercelRuntime`, `VercelHTTP` or AsyncHTTPClient.
- No full Foundation in `VercelProtocol`, `VercelRuntime`, the bootstrap or the feature modules. Use
  `#if canImport(FoundationEssentials) import FoundationEssentials #else import Foundation #endif`.
  Avoid APIs that resolve to NSString (for example `String.contains(_: String)`, see
  `percentDecoded`): they link Foundation and ICU (~40 MB) into static binaries.
  `scripts/test-linux.sh` fails if the bootstrap or HelloVapor's app contains `icudt`.

### Runtime IPC (`VERCEL_IPC_PATH`)
- The Vercel runtime decodes messages strictly: an unknown type or a wrongly typed field is fatal.
  Only send shapes that exist in `IPCMessage`, mirroring Vercel's Python runtime exactly. When
  adding one, make `scripts/fake-runtime.py` validate it just as strictly.
- Every request gets exactly one `end`. With an app connected to the bootstrap socket, `end` waits
  for the app's `release` (its `waitUntil` work). `log` and `metric` messages must never follow
  their request's `end`.
- Health checks (`/_vercel/ping`) never reach the app and produce no IPC traffic.
- Never put a file named `bootstrap` in a function: on `provided.al2023`, AWS Lambda would run it as
  the runtime, bypassing Vercel's. The handler is named `executable`.

### Request headers (`removeVercelInternalFields`, `Proxy.swift`)
- All `x-vercel-internal-*` headers are removed before the app sees the request.
- `x-vercel-internal-oidc-token` is exposed as `x-vercel-oidc-token` (unless already present).
- `x-vercel-internal-deadline` is exposed as `x-vercel-deadline`; a client-sent
  `x-vercel-deadline` is always replaced. `x-vercel-bootstrap-request` (the request token) is
  always replaced too.
- `x-vercel-sc-runtime-cache` is always removed. The other `x-vercel-sc-*` runtime cache headers
  pass through unless `x-vercel-sc-no-header-leak` is set; then the bootstrap keeps them with the
  request and hands them to the app over its socket, never as headers. They contain credentials:
  never echo them (examples included).

### Public API
- Keep `VercelRuntime`'s public API source compatible
  (`swift package diagnose-api-breaking-changes <ref> --products VercelRuntime`).
- Cross-target internals use `package` access, not `public` or `@_spi`.
- Don't give a type the same name as its module (module-qualified lookup breaks). `enum Vercel` in
  `VercelRuntime` is the one accepted exception; the umbrella module is also named `Vercel`.

### Feature modules
- Match the reference implementations on the wire so Swift and Node functions interoperate (the
  same cache entries, connection strings and headers): `@vercel/functions` (`getCache`, cache
  build client), `@vercel/edge-config`, `@vercel/firewall` (`checkRateLimit`), `@vercel/oidc` and
  `@vercel/oidc-aws-credentials-provider`, and Vercel's Python runtime. Notable details: runtime
  cache keys use djb2 over UTF-16 code units with JS 32-bit semantics; cached dates are encoded
  like JavaScript's `Date.toJSON()`; fetch metrics match the Python runtime's payload.
- Secrets never appear in `description`, `debugDescription`, `dump`/mirrors, errors or logs: tokens,
  Authorization headers, request headers, credentials. Add a test when adding a type that holds one.
- Conventions: APIs take optional `headers:` that default to `Vercel.currentRequest`; errors are
  module enums with `timedOut(Duration)`, `requestFailed(String)`, `unexpectedStatus(statusCode:)`
  and never wrap `package` types; HTTP goes through `VercelHTTPClient` (injectable; tests use
  `MockHTTPTransport`).

### Plugin
- Plugin sources can't be imported by test targets. Keep logic in PackagePlugin-free files
  (`VercelJSON.swift`, `ToolchainCheck.swift`, `SwiftVersionFile.swift`, `GitIgnore.swift`) and
  test it with `scripts/test-plugin.sh`.
- `vercel init` edits `vercel.json` by splicing text: only `installCommand`/`buildCommand` change,
  everything else stays byte-for-byte. It writes `.swift-version` only if missing, and appends
  `.vercel` to `.gitignore` only if `git check-ignore` (with global excludes disabled) says it
  isn't ignored yet.
- Inside `vercel build` (`VERCEL=1`), the plugin must not copy `crons` into `config.json`: Vercel
  adds them from `vercel.json` and rejects duplicates.

## Verifying changes

| Changed | Run |
| --- | --- |
| Anything Swift | `swift build` and `swift test` |
| Plugin | `scripts/test-plugin.sh`, plus a real `swift package --disable-sandbox vercel` / `vercel init` in a scratch package depending on this checkout by path |
| Bootstrap, protocol, runtime, examples, harness | `scripts/test-linux.sh` (Static Linux SDK build of every example + the contract harness; Docker on macOS; several minutes) |
| Install script, Git deployments | Test in an `amazonlinux:2023` container with the build image's packages, then on a real Vercel Git deployment (below) |

Report exact commands and results. Locally you need the swift.org toolchain (swiftly), not Xcode's,
and the matching Static Linux SDK (`scripts/install-static-sdk.sh` installs it).

### End-to-end on Vercel
Link a Vercel project to this repository with Root Directory set to an example (with "include files
outside the root directory", since examples depend on `../..`) and Framework Preset "Other". Every
push builds a preview from Git using the example's `vercel.json`. HelloHummingbird serves JSON
routes for the feature modules (`/request-context`, `/fetch-metric`, `/cache/:key`,
`/global-config[/:key]`, `/rate-limit/:id`, `/oidc`). Global Config needs a store and an
`EDGE_CONFIG` environment variable on the project before the deployment is created. Build logs are
available from the deployment events API (`vercel api /v3/deployments/<id>/events?builds=1`).

## Vercel platform facts (learned the hard way)

- Build image: Amazon Linux 2023, builds run as root, `HOME=/vercel`. SwiftPM finds its home in the
  user database (`/root`), not `$HOME`, so SDKs are passed with `--swift-sdks-path`.
- The build cache persists `<repo root>/.vercel/cache` (and `.vercel/builders`) for every runtime,
  per branch with a fallback to the production branch. Limit 1.5 GB compressed (3 GB / 4.75 GB on
  larger machines); over it, the whole cache is dropped. Failed deployments don't save it, and
  `vercel redeploy` skips it by default.
- The cache is restored as SquashFS, which keeps file times to the second. SwiftPM compares them to
  the nanosecond, so `.build` is cached as a POSIX tar compressed with `zstd --long` (which also
  dedupes SwiftPM's duplicate checkouts), and the toolchain and SDK get whole-second times.
- swift.org publishes an Amazon Linux 2023 toolchain; it is verified with swift.org's GPG keys
  (served gzip-encoded: use `curl --compressed`). The Static Linux SDK is downloaded with curl and
  checked with sha256: `swift sdk install <url>` can crash in URLSession on exit on Linux.
  Release names are inconsistent (`6.3` vs `6.4.0`), so versions are compared numerically.
- `vercel build` sets `VERCEL=1` and merges `vercel.json` crons into the output.
- Not available to `executable` functions today: Global Config's local files
  (`/opt/edge-config/<id>.json`, Node/Bun only; `GlobalConfig` reads them if they appear), and on
  the deployments tested, `x-vercel-sc-*` (Runtime Cache) and `x-vercel-internal-deadline`
  headers. The code handles their absence (in-memory cache fallback, `nil` deadline).
- Not implemented for lack of a documented protocol outside Node: custom metrics, cache tag purging,
  trace propagation.

## Releases

1. In one commit on `main` titled `Release X.Y.Z`: rename `## Unreleased` in `CHANGELOG.md`, bump
   `VercelJSON.release` (Plugins/VercelPlugin/VercelJSON.swift) and `VercelLibrary.version`
   (Sources/VercelHTTP/VercelLibrary.swift) together, update the pinned install script URL in
   `README.md` and `scripts/vercel-install-swift.sh`, and `from: "X.Y.Z"` in README and example
   comments. `git grep` the old version to be sure.
2. `swift build`, `swift test`, `scripts/test-plugin.sh`.
3. Push (commits on `main` must be signed), then
   `gh release create X.Y.Z --target <full sha> --title X.Y.Z --notes-file <the CHANGELOG section>`.
   Tags have no `v` prefix. Check that
   `https://raw.githubusercontent.com/vercel-labs/swift-vercel-runtime/X.Y.Z/scripts/vercel-install-swift.sh`
   returns 200: `vercel init` writes that URL.

Release bumps are the maintainer's call (patch/minor/major); propose, don't choose.

## Conventions

- Swift 6 language mode, `swift-tools-version: 6.4` (a minimum; newer toolchains work). Small,
  focused files; doc comments on public API with a usage example; `Sendable` everywhere; `Mutex`
  from Synchronization for shared state; swift-testing for tests.
- Docs: README sections are user-facing and concise; every user-visible change gets a line in the
  CHANGELOG's `## Unreleased` section.
- Work on a branch and open a PR; don't push to `main` except release commits. Don't commit
  `Package.resolved` (ignored) or `.vercel/`.
