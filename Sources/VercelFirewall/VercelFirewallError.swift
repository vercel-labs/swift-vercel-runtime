/// Why ``Firewall/checkRateLimit(_:headers:rateLimitKey:timeout:firewallHostForDevelopment:)``
/// could not check the rate limit.
public enum VercelFirewallError: Error, Sendable, Hashable, CustomStringConvertible {
    /// No `headers` were passed and the call is not inside `Vercel.withRequest`.
    case missingHeaders
    /// No `rateLimitKey` was passed and the request has no client IP (`x-real-ip`).
    case missingRateLimitKey
    /// The request has neither a `host` nor an `x-forwarded-host` header, so the firewall host is
    /// unknown.
    case missingHost
    /// The rate limit API did not answer within the timeout.
    case timedOut(Duration)
    /// The request to the rate limit API failed, for example because the host could not be
    /// reached or is not a valid host name. The string describes the failure.
    case requestFailed(String)
    /// The rate limit API answered with a status other than `204`, `429`, `403` or `404`.
    case unexpectedStatus(statusCode: Int)

    public var description: String {
        switch self {
        case .missingHeaders:
            "`headers` are required outside `Vercel.withRequest`"
        case .missingRateLimitKey:
            "Could not determine rate limit key. `rateLimitKey` is not provided and the client IP is not available."
        case .missingHost:
            "Could not determine the firewall host: the request has no `host` or `x-forwarded-host` header."
        case .timedOut(let timeout):
            "The rate-limit API request timed out after \(timeout)"
        case .requestFailed(let reason):
            "The rate-limit API request failed: \(reason)"
        case .unexpectedStatus(let statusCode):
            "Unexpected rate-limit API response status: \(statusCode)"
        }
    }
}
