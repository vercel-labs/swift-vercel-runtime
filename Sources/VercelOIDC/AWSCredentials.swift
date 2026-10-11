#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif
public import HTTPTypes
import VercelRuntime

/// Temporary AWS credentials from STS `AssumeRoleWithWebIdentity`.
///
/// Pass them to your AWS SDK as static credentials. With [Soto](https://github.com/soto-project/soto):
///
/// ```swift
/// let credentials = try await OIDC.awsCredentials(roleARN: "arn:aws:iam::123456789012:role/my-app")
/// let client = AWSClient(credentialProvider: .static(
///     accessKeyId: credentials.accessKeyID,
///     secretAccessKey: credentials.secretAccessKey,
///     sessionToken: credentials.sessionToken
/// ))
/// ```
///
/// With [aws-sdk-swift](https://github.com/awslabs/aws-sdk-swift):
///
/// ```swift
/// let credentials = try await OIDC.awsCredentials(roleARN: "arn:aws:iam::123456789012:role/my-app")
/// let resolver = StaticAWSCredentialIdentityResolver(AWSCredentialIdentity(
///     accessKey: credentials.accessKeyID,
///     secret: credentials.secretAccessKey,
///     expiration: credentials.expiration,
///     sessionToken: credentials.sessionToken
/// ))
/// let s3 = S3Client(config: try await S3Client.S3ClientConfiguration(
///     awsCredentialIdentityResolver: resolver,
///     region: "us-east-1"
/// ))
/// ```
///
/// For a long-lived SDK client, use ``AWSCredentialsProvider``, which caches credentials and
/// refreshes them before they expire.
///
/// Printing credentials, `dump` and debug descriptions show the access key ID and expiration but
/// never ``secretAccessKey`` or ``sessionToken``.
public struct AWSCredentials: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// `AccessKeyId`, for example `ASIAIOSFODNN7EXAMPLE`.
    public var accessKeyID: String
    /// `SecretAccessKey`.
    public var secretAccessKey: String
    /// `SessionToken`: required with temporary credentials.
    public var sessionToken: String
    /// `Expiration`: when the credentials stop working.
    public var expiration: Date
    /// The ARN of the assumed role session (`AssumedRoleUser/Arn`), for example
    /// `arn:aws:sts::123456789012:assumed-role/my-app/vercel-1a2b3c`, if STS returned it.
    public var assumedRoleARN: String?

    public init(
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String,
        expiration: Date,
        assumedRoleARN: String? = nil
    ) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
        self.assumedRoleARN = assumedRoleARN
    }

    /// The access key id and expiration, without the secrets, so logging credentials does not
    /// leak them.
    public var description: String {
        "AWSCredentials(accessKeyID: \(accessKeyID), expiration: \(expiration)"
            + (assumedRoleARN.map { ", assumedRoleARN: \($0)" } ?? "") + ")"
    }

    public var debugDescription: String { description }

    /// The credentials for `dump` and debuggers, with the secrets redacted.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "accessKeyID": accessKeyID,
                "secretAccessKey": "<redacted>",
                "sessionToken": "<redacted>",
                "expiration": expiration,
                "assumedRoleARN": assumedRoleARN as Any,
            ],
            displayStyle: .struct
        )
    }
}

/// Gets AWS credentials with the Vercel OIDC token and caches them until shortly before they
/// expire, like `awsCredentialsProvider` from `@vercel/functions/oidc`.
///
/// AWS SDKs ask their credential provider for credentials before every request, so create one
/// provider per role and share it. Concurrent callers share a single STS request. Each refresh
/// reads the OIDC token at that moment: from `headers`, else the current request
/// (`Vercel.currentRequest`), else `VERCEL_OIDC_TOKEN`.
///
/// ```swift
/// let provider = AWSCredentialsProvider(roleARN: "arn:aws:iam::123456789012:role/my-app", region: "us-east-1")
///
/// // In a request handler:
/// let credentials = try await provider.credentials()
/// ```
///
/// Adapt it to your SDK's credential provider protocol so the SDK refreshes on its own, for
/// example with Soto:
///
/// ```swift
/// struct VercelCredentialProvider: CredentialProvider {
///     let provider: AWSCredentialsProvider
///     var description: String { "VercelCredentialProvider" }
///
///     func getCredential(logger: Logger) async throws -> any Credential {
///         let credentials = try await provider.credentials()
///         return StaticCredential(
///             accessKeyId: credentials.accessKeyID,
///             secretAccessKey: credentials.secretAccessKey,
///             sessionToken: credentials.sessionToken
///         )
///     }
/// }
///
/// let client = AWSClient(credentialProvider: .custom { _ in VercelCredentialProvider(provider: provider) })
/// ```
///
/// Printing a provider, `dump` and debug descriptions show its role and settings, never cached
/// credentials.
public actor AWSCredentialsProvider {
    /// How long before expiration credentials are refreshed by default: 5 minutes.
    public static let defaultRefreshWindow: Duration = .seconds(300)

    /// The role to assume.
    public nonisolated let roleARN: String
    /// The session name sent with every refresh.
    public nonisolated let sessionName: String
    /// How long before ``AWSCredentials/expiration`` cached credentials are replaced. Never
    /// negative. When it is as long as the credentials' lifetime or longer, they are still used
    /// for half their lifetime instead of being refreshed on every call.
    public nonisolated let refreshWindow: Duration

    private let parameters: AssumeRoleParameters
    private let client: OIDCClient
    private var cached: AWSCredentials?
    /// When to stop using ``cached`` and refresh.
    private var refreshAt: Date?
    private var refreshing: Task<AWSCredentials, any Error>?

    /// Creates a provider. It sends no request until ``credentials(headers:forceRefresh:)``.
    ///
    /// - Parameters:
    ///   - roleARN: The IAM role to assume. Its trust policy must allow the Vercel OIDC provider
    ///     (`oidc.vercel.com/<team>` or `oidc.vercel.com`, depending on the issuer mode).
    ///   - region: The STS region. Defaults to `AWS_REGION`; without either, the global endpoint
    ///     `sts.amazonaws.com` is used.
    ///   - sessionName: The role session name, shown in CloudTrail. Defaults to `vercel-` and a
    ///     random suffix, chosen once for this provider.
    ///   - durationSeconds: How long the credentials last (900 up to the role's maximum session
    ///     duration). STS defaults to 3600.
    ///   - audience: When set, the OIDC token is first exchanged for a token with this audience
    ///     (see ``OIDC/exchange(token:audience:jti:skipCache:headers:)``).
    ///   - jti: The `jti` for the exchanged token, used only with `audience`.
    ///   - refreshWindow: How long before expiration to refresh. Defaults to 5 minutes. Negative
    ///     values count as zero. If it is as long as the credentials' lifetime (for example a
    ///     20-minute window with 15-minute credentials) or longer, credentials are refreshed after
    ///     half their lifetime instead.
    public init(
        roleARN: String,
        region: String? = nil,
        sessionName: String? = nil,
        durationSeconds: Int? = nil,
        audience: String? = nil,
        jti: String? = nil,
        refreshWindow: Duration = AWSCredentialsProvider.defaultRefreshWindow
    ) {
        self.init(
            roleARN: roleARN, region: region, sessionName: sessionName, durationSeconds: durationSeconds,
            audience: audience, jti: jti, refreshWindow: refreshWindow, client: .live
        )
    }

    init(
        roleARN: String,
        region: String?,
        sessionName: String?,
        durationSeconds: Int?,
        audience: String?,
        jti: String?,
        refreshWindow: Duration,
        client: OIDCClient
    ) {
        let sessionName = sessionName ?? randomSessionName()
        self.roleARN = roleARN
        self.sessionName = sessionName
        self.refreshWindow = max(.zero, refreshWindow)
        self.parameters = AssumeRoleParameters(
            roleARN: roleARN, region: region, sessionName: sessionName,
            durationSeconds: durationSeconds, audience: audience, jti: jti
        )
        self.client = client
    }

    /// Cached credentials, or new ones when there are none or they expire within
    /// ``refreshWindow`` (or are past half their lifetime, when the window is at least as long as
    /// the lifetime).
    ///
    /// - Parameters:
    ///   - headers: The request headers to read the OIDC token from when refreshing. Defaults to
    ///     the current request's (`Vercel.currentRequest`), then `VERCEL_OIDC_TOKEN`.
    ///   - forceRefresh: Get new credentials even if the cached ones are still valid.
    /// - Throws: ``VercelOIDCError``, or `CancellationError`.
    public func credentials(headers: HTTPFields? = nil, forceRefresh: Bool = false) async throws -> AWSCredentials {
        if !forceRefresh, let cached, let refreshAt, client.now() < refreshAt {
            return cached
        }
        if let refreshing {
            return try await refreshing.value
        }
        let headers = headers ?? Vercel.currentRequest?.headers
        let task = Task { () async throws -> AWSCredentials in
            defer { self.refreshing = nil }
            let obtainedAt = self.client.now()
            let credentials = try await self.client.awsCredentials(self.parameters, headers: headers)
            self.cached = credentials
            self.refreshAt = Self.refreshDate(for: credentials, obtainedAt: obtainedAt, refreshWindow: self.refreshWindow)
            return credentials
        }
        refreshing = task
        return try await task.value
    }

    /// Drops the cached credentials, so the next ``credentials(headers:forceRefresh:)`` call gets
    /// new ones.
    public func invalidate() {
        cached = nil
        refreshAt = nil
    }

    /// When to refresh `credentials` obtained at `obtainedAt`: `refreshWindow` before they expire,
    /// or halfway through their lifetime when the window is at least as long as the lifetime.
    static func refreshDate(for credentials: AWSCredentials, obtainedAt: Date, refreshWindow: Duration) -> Date {
        let lifetime = credentials.expiration.timeIntervalSince(obtainedAt)
        let window = seconds(refreshWindow)
        guard lifetime > 0 else { return credentials.expiration }
        return credentials.expiration.addingTimeInterval(-(window < lifetime ? window : lifetime / 2))
    }
}

extension AWSCredentialsProvider: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The role and settings, without any credentials.
    public nonisolated var description: String {
        "AWSCredentialsProvider(roleARN: \(roleARN), sessionName: \(sessionName), refreshWindow: \(refreshWindow))"
    }

    public nonisolated var debugDescription: String { description }

    /// The role and settings for `dump` and debuggers, without cached credentials or tokens.
    public nonisolated var customMirror: Mirror {
        Mirror(
            self,
            children: ["roleARN": roleARN, "sessionName": sessionName, "refreshWindow": refreshWindow],
            displayStyle: .class
        )
    }
}

private func seconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) + Double(attoseconds) / 1e18
}
