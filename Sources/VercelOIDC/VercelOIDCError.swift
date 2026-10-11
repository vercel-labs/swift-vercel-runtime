/// Why getting, decoding or exchanging a Vercel OIDC token, or assuming an AWS role with it, failed.
///
/// Like the other Vercel feature modules' errors, network failures are ``timedOut(_:)`` or
/// ``requestFailed(_:)``; unexpected statuses are ``exchangeFailed(statusCode:message:)`` and
/// ``awsSTS(statusCode:code:message:)``, with what the endpoint said. None of them contain tokens.
public enum VercelOIDCError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The request has no `x-vercel-oidc-token` header and `VERCEL_OIDC_TOKEN` is not set.
    ///
    /// On Vercel, enable OIDC (Secure backend access) in the project settings and pass the request
    /// headers, or call inside `Vercel.withRequest`. Locally, run `vercel env pull` and load the
    /// resulting `.env.local` into the environment.
    case missingToken
    /// The token is not a JWT whose payload is a base64url-encoded JSON object.
    case malformedToken(reason: String)
    /// The token exchange endpoint answered with a non-2xx status. `message` is the endpoint's
    /// `error` field, or the status if it sent none.
    case exchangeFailed(statusCode: Int, message: String)
    /// The token exchange endpoint answered 2xx, but not with `{"token": "..."}`.
    case invalidExchangeResponse(reason: String)
    /// The region is not a valid AWS region name (lowercase letters, digits and `-`).
    case invalidRegion(String)
    /// AWS STS rejected `AssumeRoleWithWebIdentity`, with the STS error `code` (for example
    /// `InvalidIdentityToken` or `AccessDenied`) and `message`, when the response had them.
    case awsSTS(statusCode: Int, code: String?, message: String?)
    /// AWS STS answered 2xx, but the response lacked the credentials.
    case invalidSTSResponse(reason: String)
    /// The token exchange or STS endpoint did not answer within the timeout (30 seconds).
    case timedOut(Duration)
    /// The request failed before a complete response arrived, for example because the host could
    /// not be reached or the response was too large. The string describes the failure, with the
    /// request's method and URL.
    case requestFailed(String)

    public var description: String {
        switch self {
        case .missingToken:
            "The 'x-vercel-oidc-token' header is missing from the request and VERCEL_OIDC_TOKEN is not set. "
                + "Enable OIDC in the project settings on Vercel; locally, run `vercel env pull`."
        case .malformedToken(let reason):
            "Invalid Vercel OIDC token: \(reason)"
        case .exchangeFailed(let status, let message):
            "Failed to exchange token (HTTP \(status)): \(message)"
        case .invalidExchangeResponse(let reason):
            "Failed to exchange token: \(reason)"
        case .invalidRegion(let region):
            "Invalid AWS region: \(region)"
        case .awsSTS(let status, let code, let message):
            "AWS STS AssumeRoleWithWebIdentity failed (HTTP \(status))"
                + (code.map { ": \($0)" } ?? "")
                + (message.map { " - \($0)" } ?? "")
        case .invalidSTSResponse(let reason):
            "Invalid AWS STS AssumeRoleWithWebIdentity response: \(reason)"
        case .timedOut(let timeout):
            "The request timed out after \(timeout)"
        case .requestFailed(let reason):
            "The request failed: \(reason)"
        }
    }
}
