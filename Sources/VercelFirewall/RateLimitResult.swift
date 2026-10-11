/// The outcome of ``Firewall/checkRateLimit(_:headers:rateLimitKey:timeout:firewallHostForDevelopment:)``.
///
/// Matches the object returned by `checkRateLimit` from `@vercel/firewall`, whose `error` field is
/// ``reason`` here.
public struct RateLimitResult: Sendable, Hashable {
    /// Why a rate limit check did not give a regular answer. Reported in ``RateLimitResult/reason``
    /// rather than thrown, like the `error` field in `@vercel/firewall`.
    public enum Reason: String, Sendable, Hashable {
        /// No rate limit rule with this ID is configured in the Vercel Firewall (`404`). The
        /// request is not rate limited.
        case notFound = "not-found"
        /// The Vercel Firewall blocked the check itself (`403`). The request counts as rate limited.
        case blocked
    }

    /// Whether the request is over the limit (or blocked by the firewall). Respond with
    /// `429 Too Many Requests` and skip the guarded work when `true`.
    public var rateLimited: Bool
    /// Why the check did not give a regular answer, `nil` when it did.
    public var reason: Reason?

    public init(rateLimited: Bool, reason: Reason? = nil) {
        self.rateLimited = rateLimited
        self.reason = reason
    }
}
