import HTTPTypes

/// Sends one HTTP request and returns the response with its whole body.
///
/// ``VercelHTTPClient`` uses ``AsyncHTTPClientTransport`` by default; tests inject
/// ``MockHTTPTransport``.
package protocol HTTPTransport: Sendable {
    /// Sends `request` and collects the response body.
    ///
    /// - Parameters:
    ///   - request: The request. Its `scheme`, `authority` and `path` (with the query) form the URL.
    ///   - body: The request body, or `nil` for none.
    ///   - timeout: How long the whole exchange, including the response body, may take.
    ///   - followRedirects: Whether to follow `3xx` responses. When `false`, they are returned.
    ///   - maxResponseBodySize: The largest response body to accept, in bytes. Larger bodies throw
    ///     ``VercelHTTPError/responseTooLarge(method:url:limit:)``.
    func send(
        _ request: HTTPRequest,
        body: [UInt8]?,
        timeout: Duration,
        followRedirects: Bool,
        maxResponseBodySize: Int
    ) async throws -> (HTTPResponse, [UInt8])
}
