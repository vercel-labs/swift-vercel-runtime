/// Why a ``RuntimeCache`` operation failed.
///
/// Only the Vercel Runtime Cache service throws these; the in-memory fallback never fails.
/// Encoding and decoding values throws `EncodingError` and `DecodingError` as usual, and a
/// cancelled task throws `CancellationError`.
///
/// The same three failures as the other Vercel feature modules' errors (`timedOut`,
/// `requestFailed`, `unexpectedStatus`), each with the ``Operation`` that failed.
public enum RuntimeCacheError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A cache operation.
    public enum Operation: String, Sendable, Hashable {
        case get
        case set
        case delete
        case expireTag
    }

    /// The cache did not answer within the timeout (500 ms unless `RUNTIME_CACHE_TIMEOUT` sets
    /// another number of milliseconds).
    case timedOut(Duration, operation: Operation)
    /// The request failed before a response arrived, for example because the cache could not be
    /// reached. The string describes the failure.
    case requestFailed(String, operation: Operation)
    /// The cache answered with an unexpected status: anything but `200` (and `404` for
    /// ``RuntimeCache/get(_:as:)``).
    case unexpectedStatus(statusCode: Int, operation: Operation)

    /// The operation that failed.
    public var operation: Operation {
        switch self {
        case .timedOut(_, let operation), .requestFailed(_, let operation), .unexpectedStatus(_, let operation):
            operation
        }
    }

    public var description: String {
        switch self {
        case .timedOut(let timeout, let operation):
            "Runtime Cache \(operation.rawValue) timed out after \(timeout)"
        case .requestFailed(let reason, let operation):
            "Runtime Cache \(operation.rawValue) failed: \(reason)"
        case .unexpectedStatus(let statusCode, let operation):
            "Runtime Cache \(operation.rawValue) failed with status \(statusCode)"
        }
    }
}
