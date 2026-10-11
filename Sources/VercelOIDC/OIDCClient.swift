#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import VercelHTTP
import VercelRuntime

/// The `User-Agent` sent with every OIDC and STS request.
let userAgent = "swift-vercel-runtime/\(VercelLibrary.version)"

/// What the OIDC functions depend on, so tests can replace the network, environment and clock.
/// ``OIDC`` and ``AWSCredentialsProvider`` use ``live``.
struct OIDCClient: Sendable {
    var http: VercelHTTPClient
    /// Reads an environment variable; empty values count as unset.
    var environment: @Sendable (String) -> String?
    var now: @Sendable () -> Date
    var exchangeCache: ExchangeCache

    /// The process environment, the system clock and the process-wide exchange cache.
    static var live: OIDCClient {
        OIDCClient(
            http: VercelHTTPClient(),
            environment: { name in
                guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
                return value
            },
            now: { Date() },
            exchangeCache: .shared
        )
    }

    /// The request's `x-vercel-oidc-token` header (from `headers`, else the current request), else
    /// `VERCEL_OIDC_TOKEN`.
    func token(headers: HTTPFields?) throws(VercelOIDCError) -> String {
        if let value = (headers ?? Vercel.currentRequest?.headers)?[.vercelOIDCToken], !value.isEmpty {
            return value
        }
        if let value = environment("VERCEL_OIDC_TOKEN") {
            return value
        }
        throw .missingToken
    }

    /// How long each token exchange or STS request may take.
    static let timeout: Duration = .seconds(30)

    /// Sends a request, turning transport failures into ``VercelOIDCError/timedOut(_:)`` and
    /// ``VercelOIDCError/requestFailed(_:)``. `requestHeaders` are the caller's explicit request
    /// headers, for the fetch metric.
    func send(
        _ method: HTTPRequest.Method,
        _ url: String,
        headerFields: HTTPFields,
        body: [UInt8],
        requestHeaders: HTTPFields?
    ) async throws -> VercelHTTPResponse {
        do {
            return try await http.send(
                method,
                url,
                headerFields: headerFields,
                body: body,
                timeout: Self.timeout,
                incomingRequestHeaders: requestHeaders
            )
        } catch let error as VercelHTTPError {
            if let timeout = error.timeout {
                throw VercelOIDCError.timedOut(timeout)
            }
            throw VercelOIDCError.requestFailed(error.description)
        }
    }
}

extension HTTPField.Name {
    static let vercelOIDCToken = Self("x-vercel-oidc-token")!
}
