public import HTTPTypes

/// Vercel OIDC tokens: authenticate with cloud providers and your own services without long-lived
/// secrets, like `@vercel/oidc`.
///
/// On Vercel, with OIDC enabled in the project settings (Secure backend access), every request
/// carries a short-lived token in the `x-vercel-oidc-token` header. Locally, `vercel env pull`
/// writes one to `.env.local` as `VERCEL_OIDC_TOKEN`; load it into the environment (it expires
/// after about 12 hours, so pull again when it does).
///
/// ```swift
/// // Send the token to a service that trusts Vercel's OIDC issuer.
/// let token = try OIDC.token()
///
/// // Or trade it for temporary AWS credentials.
/// let credentials = try await OIDC.awsCredentials(roleARN: "arn:aws:iam::123456789012:role/my-app")
/// ```
///
/// Without explicit `headers`, the functions use the request set by `Vercel.withRequest`.
///
/// The namespace is `OIDC`, not `VercelOIDC`, so it never shadows the module: write
/// `OIDC.token()`, or `VercelOIDC.OIDC.token()` to qualify it.
public enum OIDC {
    /// The OIDC token for the request: the `x-vercel-oidc-token` header from `headers` (default:
    /// `Vercel.currentRequest`), else the `VERCEL_OIDC_TOKEN` environment variable.
    ///
    /// Do not store the token: it is per request and short-lived. Like `getVercelOidcTokenSync`
    /// from `@vercel/oidc`, this does not refresh an expired token; use ``VercelOIDCToken`` to check
    /// its expiration.
    ///
    /// ```swift
    /// // Hummingbird
    /// router.get("/data") { request, _ in
    ///     let token = try OIDC.token(headers: request.headers)
    ///     // Authorization: Bearer <token>
    /// }
    /// ```
    ///
    /// - Throws: ``VercelOIDCError/missingToken`` when there is neither.
    public static func token(headers: HTTPFields? = nil) throws(VercelOIDCError) -> String {
        try OIDCClient.live.token(headers: headers)
    }

    /// Exchanges the OIDC token for a Vercel-issued token with a custom audience, like
    /// `exchangeVercelOidcToken` from `@vercel/oidc` (`POST https://oidc.vercel.com/~token`).
    ///
    /// Use it when a service expects its own audience, such as `https://sts.amazonaws.com`.
    /// Exchanged tokens are cached in memory until they expire (up to 1000, least recently used
    /// first out), keyed by the source token, `audience` and `jti`, so calling this on every
    /// request is cheap. Concurrent calls with the same key share one request.
    ///
    /// ```swift
    /// let token = try await OIDC.exchange(audience: "https://api.example.com")
    /// ```
    ///
    /// - Parameters:
    ///   - token: The token to exchange. Defaults to ``token(headers:)``.
    ///   - audience: The `aud` of the exchanged token.
    ///   - jti: The `jti` of the exchanged token. A unique value per call also makes every call
    ///     exchange anew, since it is part of the cache key.
    ///   - skipCache: Exchange even if a cached token exists (joining an exchange already in
    ///     flight for the same key). The new token replaces the cached one.
    ///   - headers: The request headers to read the token from when `token` is `nil`.
    /// - Throws: ``VercelOIDCError``, or `CancellationError`.
    public static func exchange(
        token: String? = nil,
        audience: String? = nil,
        jti: String? = nil,
        skipCache: Bool = false,
        headers: HTTPFields? = nil
    ) async throws -> String {
        let client = OIDCClient.live
        let source = try token ?? client.token(headers: headers)
        return try await client.exchange(token: source, audience: audience, jti: jti, skipCache: skipCache, headers: headers)
    }

    /// Temporary AWS credentials for `roleARN`, from STS `AssumeRoleWithWebIdentity` with the OIDC
    /// token.
    ///
    /// Every call asks STS for new credentials; use ``AWSCredentialsProvider`` to cache them. The
    /// STS request is unsigned, so no AWS credentials are needed to make it.
    ///
    /// ```swift
    /// let credentials = try await OIDC.awsCredentials(
    ///     roleARN: "arn:aws:iam::123456789012:role/my-app",
    ///     region: "us-east-1"
    /// )
    /// ```
    ///
    /// See ``AWSCredentials`` for passing them to Soto or aws-sdk-swift.
    ///
    /// - Parameters:
    ///   - roleARN: The IAM role to assume. Its trust policy must allow the Vercel OIDC provider.
    ///   - region: The STS region (`https://sts.<region>.amazonaws.com`). Defaults to `AWS_REGION`;
    ///     without either, the global endpoint `https://sts.amazonaws.com` is used.
    ///   - sessionName: The role session name, shown in CloudTrail. Defaults to `vercel-` and a
    ///     random suffix.
    ///   - durationSeconds: How long the credentials last (900 up to the role's maximum session
    ///     duration). STS defaults to 3600.
    ///   - audience: When set, the OIDC token is first exchanged for a token with this audience
    ///     (see ``exchange(token:audience:jti:skipCache:headers:)``).
    ///   - jti: The `jti` for the exchanged token, used only with `audience`.
    ///   - headers: The request headers to read the OIDC token from. Defaults to
    ///     `Vercel.currentRequest`, then `VERCEL_OIDC_TOKEN`.
    /// - Throws: ``VercelOIDCError`` (for STS failures ``VercelOIDCError/awsSTS(statusCode:code:message:)``),
    ///   or `CancellationError`.
    public static func awsCredentials(
        roleARN: String,
        region: String? = nil,
        sessionName: String? = nil,
        durationSeconds: Int? = nil,
        audience: String? = nil,
        jti: String? = nil,
        headers: HTTPFields? = nil
    ) async throws -> AWSCredentials {
        try await OIDCClient.live.awsCredentials(
            AssumeRoleParameters(
                roleARN: roleARN, region: region, sessionName: sessionName,
                durationSeconds: durationSeconds, audience: audience, jti: jti
            ),
            headers: headers
        )
    }
}
