import HTTPTypes
import Synchronization

/// An ``HTTPTransport`` for tests: records every request and answers with scripted responses.
///
/// ```swift
/// let transport = MockHTTPTransport(responses: [.init(status: .ok, body: #"{"a":1}"#)])
/// let client = VercelHTTPClient(transport: transport)
/// // ... exercise code using `client` ...
/// #expect(transport.requests.first?.request.path == "/v1/items")
/// ```
package final class MockHTTPTransport: HTTPTransport {
    /// A request the transport received.
    package struct Request: Sendable {
        package var request: HTTPRequest
        package var body: [UInt8]?
        package var timeout: Duration
        package var followRedirects: Bool

        /// The body as UTF-8 text, `nil` without a body.
        package var text: String? { body.map { String(decoding: $0, as: UTF8.self) } }
    }

    /// A scripted response.
    package struct Response: Sendable {
        package var status: HTTPResponse.Status
        package var headerFields: HTTPFields
        package var body: [UInt8]

        package init(status: HTTPResponse.Status, headerFields: HTTPFields = [:], body: [UInt8] = []) {
            self.status = status
            self.headerFields = headerFields
            self.body = body
        }

        package init(status: HTTPResponse.Status, headerFields: HTTPFields = [:], body: String) {
            self.init(status: status, headerFields: headerFields, body: Array(body.utf8))
        }
    }

    /// Thrown when a request arrives after the scripted responses ran out.
    package struct NoMoreResponses: Error, Sendable {
        package var request: HTTPRequest
    }

    private let handler: @Sendable (Request) async throws -> Response
    private let recorded = Mutex<[Request]>([])

    /// Answers each request with `handler`, which may also throw to simulate a transport failure.
    package init(_ handler: @escaping @Sendable (Request) async throws -> Response) {
        self.handler = handler
    }

    /// Answers requests with `responses` in order, then throws ``NoMoreResponses``.
    package convenience init(responses: [Response]) {
        let queue = Mutex(responses[...])
        self.init { request in
            guard let response = queue.withLock({ $0.popFirst() }) else {
                throw NoMoreResponses(request: request.request)
            }
            return response
        }
    }

    /// Every request received so far, oldest first.
    package var requests: [Request] {
        recorded.withLock { $0 }
    }

    package func send(
        _ request: HTTPRequest,
        body: [UInt8]?,
        timeout: Duration,
        followRedirects: Bool,
        maxResponseBodySize: Int
    ) async throws -> (HTTPResponse, [UInt8]) {
        let request = Request(request: request, body: body, timeout: timeout, followRedirects: followRedirects)
        recorded.withLock { $0.append(request) }
        let response = try await handler(request)
        return (HTTPResponse(status: response.status, headerFields: response.headerFields), response.body)
    }
}
