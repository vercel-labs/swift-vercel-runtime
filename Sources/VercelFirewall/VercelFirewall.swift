public import HTTPTypes
import Logging
import Synchronization
package import VercelHTTP
package import VercelRuntime

/// Rate limiting with rules defined in the Vercel Firewall, like `checkRateLimit` from
/// `@vercel/firewall`.
///
/// ## Configure the Vercel Firewall
///
/// Rate limits live in the Vercel Firewall, not in code. For each limit:
///
/// 1. In the Vercel dashboard, open the project's **Firewall** tab and add a custom rule.
/// 2. Add the condition **@vercel/firewall** (Rate limit API ID) and enter an ID, for example
///    `login`. Use the same ID in ``checkRateLimit(_:headers:rateLimitKey:timeout:firewallHostForDevelopment:)``.
/// 3. Choose the **Rate Limit** action with its algorithm, window and number of requests, and
///    publish the rule.
///
/// Calls with an ID that has no rule return ``RateLimitResult/reason`` ``RateLimitResult/Reason/notFound``
/// and are not rate limited.
///
/// Optional environment variables, read like `@vercel/firewall`:
/// - `RATE_LIMIT_SECRET`: mixed into the hashed rate limit key.
/// - `PUBLIC_VERCEL_FIREWALL_PATH_PREFIX` (or `NEXT_PUBLIC_VERCEL_FIREWALL_PATH_PREFIX`): a path
///   prefix for the rate limit API, when the deployment is served under one.
/// - `VERCEL_AUTOMATION_BYPASS_SECRET`: sent as `x-vercel-protection-bypass` so checks work on
///   deployments with Deployment Protection.
///
/// ## Use it in a handler
///
/// ```swift
/// // Hummingbird 2
/// router.post("login") { request, _ -> Response in
///     let result = try await Firewall.checkRateLimit("login", headers: request.headers)
///     if result.rateLimited {
///         return Response(status: .tooManyRequests)
///     }
///     // Work guarded by the rate limit.
///     return Response(status: .ok)
/// }
///
/// // Vapor 5
/// app.post("login") { request async throws -> Response in
///     let result = try await Firewall.checkRateLimit("login", headers: request.headers)
///     if result.rateLimited {
///         return Response(status: .tooManyRequests)
///     }
///     // Work guarded by the rate limit.
///     return Response(status: .ok)
/// }
/// ```
///
/// Inside `Vercel.withRequest` (for example from a middleware), `headers` can be omitted.
///
/// The namespace is `Firewall`, not `VercelFirewall`, so it never shadows the module: write
/// `Firewall.checkRateLimit(...)`, or `VercelFirewall.Firewall.checkRateLimit(...)` to qualify it.
public enum Firewall {
    /// Checks the Vercel Firewall rate limit rule with this ID for the current request.
    ///
    /// Sends `GET https://{host}{prefix}/.well-known/vercel/rate-limit-api/{id}` to the
    /// deployment's own host, which the Vercel Firewall answers: `204` (not limited), `429`
    /// (limited), `403` (blocked: limited, ``RateLimitResult/Reason/blocked``) or `404` (no rule
    /// with this ID: not limited, ``RateLimitResult/Reason/notFound``, logged as a warning). Redirects are not
    /// followed.
    ///
    /// The rate limit key (by default the client IP from `x-real-ip`) is sent as
    /// `{key}-{sha256(key + id + VERCEL_AUTOMATION_BYPASS_SECRET + RATE_LIMIT_SECRET)}`, so Node
    /// and Swift functions share the same counters. Every request header is forwarded as
    /// `x-rr-{name}`, for rules that match on request properties (except `VercelBootstrap`'s
    /// private request token, `x-vercel-bootstrap-request`), as is the `_vercel_jwt` cookie
    /// (Vercel Authentication). The ID is encoded like `encodeURIComponent`.
    ///
    /// **Development**: `@vercel/firewall` treats `NODE_ENV !== 'production'` as development.
    /// Here it is development when not running on Vercel (the `VERCEL` environment variable is
    /// not `1`) or when `VERCEL_ENV` is `development`. In development, without
    /// `firewallHostForDevelopment` the check logs a warning (once per process) and returns not
    /// limited without sending a request; with it, it checks the rules of that host instead of
    /// the request's.
    ///
    /// - Parameters:
    ///   - id: The rate limit ID, as configured in the Vercel Firewall rule's **@vercel/firewall**
    ///     condition.
    ///   - headers: The request's header fields. Defaults to `Vercel.currentRequest`. The firewall
    ///     host comes from `host`, or `x-forwarded-host` when the server moved `Host` out of the
    ///     header fields (Hummingbird and Vapor 5 do).
    ///   - rateLimitKey: The entity being rate limited, for example a user ID. Defaults to the
    ///     client IP (`x-real-ip`).
    ///   - timeout: How long the check may take. Defaults to 30 seconds (`@vercel/firewall` has no
    ///     default timeout).
    ///   - firewallHostForDevelopment: In development, the host whose firewall rules to check, for
    ///     example `my-app.vercel.app`. Ignored on Vercel.
    /// - Throws: ``VercelFirewallError`` when the check cannot be made or the rate limit API
    ///   answers unexpectedly, or `CancellationError`.
    public static func checkRateLimit(
        _ id: String,
        headers: HTTPFields? = nil,
        rateLimitKey: String? = nil,
        timeout: Duration? = nil,
        firewallHostForDevelopment: String? = nil
    ) async throws -> RateLimitResult {
        try await checkRateLimit(
            id,
            headers: headers,
            rateLimitKey: rateLimitKey,
            timeout: timeout,
            firewallHostForDevelopment: firewallHostForDevelopment,
            environment: .firewall,
            client: VercelHTTPClient()
        )
    }

    /// ``checkRateLimit(_:headers:rateLimitKey:timeout:firewallHostForDevelopment:)`` with an
    /// explicit environment and HTTP client, for tests.
    package static func checkRateLimit(
        _ id: String,
        headers: HTTPFields? = nil,
        rateLimitKey: String? = nil,
        timeout: Duration? = nil,
        firewallHostForDevelopment: String? = nil,
        environment: VercelEnvironment,
        client: VercelHTTPClient
    ) async throws -> RateLimitResult {
        // `@vercel/firewall` treats empty strings as missing.
        let developmentHost = firewallHostForDevelopment.flatMap { $0.isEmpty ? nil : $0 }
        let isDevelopment = environment.isFirewallDevelopment
        if isDevelopment, developmentHost == nil {
            warnAboutDevelopmentOnce()
            return RateLimitResult(rateLimited: false)
        }

        guard let requestHeaders = headers ?? Vercel.currentRequest?.headers else {
            throw VercelFirewallError.missingHeaders
        }

        var firewallHost = nonEmpty(requestHeaders[FieldName.host]) ?? nonEmpty(requestHeaders[FieldName.forwardedHost])
        if isDevelopment, developmentHost != ignoreForTesting {
            firewallHost = developmentHost
        }

        guard let key = nonEmpty(rateLimitKey) ?? nonEmpty(requestHeaders[FieldName.realIP]) else {
            throw VercelFirewallError.missingRateLimitKey
        }
        guard let firewallHost else {
            throw VercelFirewallError.missingHost
        }

        let url = "https://\(firewallHost)\(environment.firewallPathPrefix)/.well-known/vercel/rate-limit-api/\(uriComponentEncoded(id))"
        let bypassSecret = environment["VERCEL_AUTOMATION_BYPASS_SECRET"] ?? ""
        let fullKey = "\(key)-\(SHA256.hexDigest(key + id + bypassSecret + (environment["RATE_LIMIT_SECRET"] ?? "")))"

        let request: HTTPRequest
        do {
            request = try HTTPRequest(
                method: .get,
                urlString: url,
                headerFields: rateLimitHeaderFields(id: id, fullKey: fullKey, bypassSecret: bypassSecret, requestHeaders: requestHeaders)
            )
        } catch {
            throw VercelFirewallError.requestFailed(error.description)
        }

        let response: VercelHTTPResponse
        do {
            response = try await client.send(
                request,
                timeout: timeout ?? VercelHTTPClient.defaultTimeout,
                followRedirects: false,
                incomingRequestHeaders: headers
            )
        } catch let error as VercelHTTPError {
            if let timeout = error.timeout {
                throw VercelFirewallError.timedOut(timeout)
            }
            throw VercelFirewallError.requestFailed(error.description)
        }

        switch response.status.code {
        case 204:
            return RateLimitResult(rateLimited: false)
        case 429:
            return RateLimitResult(rateLimited: true)
        case 403:
            return RateLimitResult(rateLimited: true, reason: .blocked)
        case 404:
            logger.warning("Rate-limit ID '\(id)' not configured")
            return RateLimitResult(rateLimited: false, reason: .notFound)
        case let status:
            throw VercelFirewallError.unexpectedStatus(statusCode: status)
        }
    }

    /// The header fields of the rate limit API request, in `@vercel/firewall`'s order.
    static func rateLimitHeaderFields(id: String, fullKey: String, bypassSecret: String, requestHeaders: HTTPFields) -> HTTPFields {
        var fields: HTTPFields = [
            FieldName.rateLimitAPI: id,
            FieldName.rateLimitKey: fullKey,
            .userAgent: "Bot/Vercel Rate Limit Checker",
            FieldName.forwardedFor: requestHeaders[FieldName.forwardedFor] ?? "",
            FieldName.realIP: requestHeaders[FieldName.realIP] ?? "",
            FieldName.protectionBypass: bypassSecret,
        ]
        // Forward the auth cookie if it exists.
        if let jwt = cookieValue(named: "_vercel_jwt", in: requestHeaders[.cookie]), !jwt.isEmpty {
            fields.append(HTTPField(name: .cookie, value: "_vercel_jwt=\(jwt)"))
        }
        // Like iterating a fetch `Headers` object: one field per name, with repeated fields
        // combined (`; ` for cookies, `, ` otherwise), except `set-cookie`. The bootstrap's request
        // token is private to this deployment's app and never leaves it.
        var copied: Set<HTTPField.Name> = []
        for field in requestHeaders where field.name != FieldName.bootstrapRequest {
            guard let name = HTTPField.Name("x-rr-\(field.name.canonicalName)") else { continue }
            if field.name == .setCookie {
                fields.append(HTTPField(name: name, value: field.value))
            } else if copied.insert(field.name).inserted, let value = requestHeaders[field.name] {
                fields.append(HTTPField(name: name, value: value))
            }
        }
        return fields
    }
}

/// The value of the cookie `name` in a `Cookie` header, parsed like `@vercel/firewall`: pairs
/// split on `;` and trimmed, the last pair with the name wins, a pair without `=` has an empty
/// value.
func cookieValue(named name: String, in header: String?) -> String? {
    guard let header, !header.isEmpty else { return nil }
    var found: String?
    for pair in header.split(separator: ";", omittingEmptySubsequences: false) {
        let trimmed = pair.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed()
        let cookie = String(trimmed)
        if let equals = cookie.firstIndex(of: "=") {
            if cookie[..<equals] == name {
                found = String(cookie[cookie.index(after: equals)...])
            }
        } else if cookie == name {
            found = ""
        }
    }
    return found
}

/// The `firewallHostForDevelopment` value that makes development use the request's host, as in
/// `@vercel/firewall`'s tests.
private let ignoreForTesting = "ignore-for-testing"

private let logger = Logger(label: "vercel.firewall")
private let warnedAboutDevelopment = Mutex(false)

private func warnAboutDevelopmentOnce() {
    let first = warnedAboutDevelopment.withLock { warned in
        defer { warned = true }
        return !warned
    }
    if first {
        logger.warning("Provide the `firewallHostForDevelopment` option to support rate-limiting in development mode")
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

/// Header names, namespaced so they cannot clash with other modules' `HTTPField.Name` extensions.
private enum FieldName {
    static let host = HTTPField.Name("host")!
    static let forwardedHost = HTTPField.Name("x-forwarded-host")!
    static let forwardedFor = HTTPField.Name("x-forwarded-for")!
    static let realIP = HTTPField.Name("x-real-ip")!
    static let rateLimitAPI = HTTPField.Name("x-vercel-rate-limit-api")!
    static let rateLimitKey = HTTPField.Name("x-vercel-rate-limit-key")!
    static let protectionBypass = HTTPField.Name("x-vercel-protection-bypass")!
    /// `BootstrapProtocol.requestHeader`, which this module can't import: the token
    /// `VercelBootstrap` adds to each request it proxies to the app.
    static let bootstrapRequest = HTTPField.Name("x-vercel-bootstrap-request")!
}
