/// Why an HTTP request made by ``VercelHTTPClient`` failed. Responses with error status codes are
/// not errors at this level: callers decide what each status means.
package enum VercelHTTPError: Error, Sendable, CustomStringConvertible {
    /// The URL could not be parsed into a scheme, host and path.
    case invalidURL(String)
    /// No complete response arrived within `timeout`.
    case timedOut(method: String, url: String, timeout: Duration)
    /// The response body was larger than `limit` bytes.
    case responseTooLarge(method: String, url: String, limit: Int)
    /// The request failed before a complete response arrived, for example because the host could
    /// not be reached.
    case transport(method: String, url: String, underlying: any Error)

    /// Describes the failure. Credentials in URLs (`https://user:password@host`) are redacted.
    package var description: String {
        switch self {
        case .invalidURL(let url):
            "Invalid URL: \(redactingUserInfo(url))"
        case .timedOut(let method, let url, let timeout):
            "\(method) \(redactingUserInfo(url)) timed out after \(milliseconds(timeout)) ms"
        case .responseTooLarge(let method, let url, let limit):
            "\(method) \(redactingUserInfo(url)) response body is larger than \(limit) bytes"
        case .transport(let method, let url, let underlying):
            "\(method) \(redactingUserInfo(url)) failed: \(underlying)"
        }
    }

    /// The timeout that passed, for ``timedOut(method:url:timeout:)``; `nil` for other failures.
    ///
    /// The feature modules map this error into their own public error types, so this package
    /// type never reaches apps:
    ///
    /// ```swift
    /// catch let error as VercelHTTPError {
    ///     if let timeout = error.timeout { throw MyError.timedOut(timeout) }
    ///     throw MyError.requestFailed(error.description)
    /// }
    /// ```
    package var timeout: Duration? {
        if case .timedOut(_, _, let timeout) = self { timeout } else { nil }
    }
}

/// Whole milliseconds in `duration`, rounded down and never negative.
private func milliseconds(_ duration: Duration) -> Int64 {
    let (seconds, attoseconds) = duration.components
    let (product, overflow) = seconds.multipliedReportingOverflow(by: 1000)
    guard !overflow else { return seconds < 0 ? 0 : .max }
    return max(0, product + attoseconds / 1_000_000_000_000_000)
}
