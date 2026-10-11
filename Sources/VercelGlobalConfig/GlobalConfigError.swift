/// Why a ``GlobalConfig`` could not be created or a read failed.
///
/// Reads throw these or, when a value does not decode as the requested type, `DecodingError`.
/// A cancelled task throws `CancellationError`.
public enum GlobalConfigError: Error, Sendable, Hashable, CustomStringConvertible {
    /// No connection string was passed, or the environment variable (`EDGE_CONFIG` by default) is
    /// unset or empty.
    case missingConnectionString
    /// The connection string is not in one of the supported forms. See
    /// ``GlobalConfig/Connection/init(connectionString:)``.
    case invalidConnectionString
    /// The store rejected the token (HTTP 401).
    case unauthorized
    /// The store does not exist (HTTP 404 without an `x-edge-config-digest` header).
    case storeNotFound
    /// The store did not answer within the client's timeout.
    case timedOut(Duration)
    /// The request failed before a response arrived, for example because the store could not be
    /// reached. The string describes the failure; it never contains the token.
    case requestFailed(String)
    /// The store answered with an unexpected HTTP status code.
    case unexpectedStatus(statusCode: Int)

    public var description: String {
        switch self {
        case .missingConnectionString:
            "Vercel Global Config: No connection string provided. Set EDGE_CONFIG or pass one explicitly."
        case .invalidConnectionString:
            "Vercel Global Config: Invalid connection string provided"
        case .unauthorized:
            "Vercel Global Config: Unauthorized"
        case .storeNotFound:
            "Vercel Global Config: Global Config not found"
        case .timedOut(let timeout):
            "Vercel Global Config: The request timed out after \(timeout)"
        case .requestFailed(let reason):
            "Vercel Global Config: The request failed: \(reason)"
        case .unexpectedStatus(let statusCode):
            "Vercel Global Config: Unexpected error due to response with status code \(statusCode)"
        }
    }
}
