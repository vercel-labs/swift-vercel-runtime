#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import AsyncHTTPClient
import HTTPTypes
import VercelRuntime

/// The HTTP client the Vercel feature modules share.
///
/// Sends each request through an ``HTTPTransport``, caps the response body, reports the request to
/// Vercel Observability (External APIs) with ``Vercel/reportFetch(method:host:path:query:statusCode:start:duration:)``
/// and turns transport failures into ``VercelHTTPError``.
package struct VercelHTTPClient: Sendable {
    /// The largest response body accepted by default: 10 MB.
    package static let defaultMaxResponseBodySize = 10 * 1024 * 1024
    /// How long a request may take by default.
    package static let defaultTimeout: Duration = .seconds(30)

    /// Sends the requests.
    package var transport: any HTTPTransport
    /// The largest response body to accept, in bytes.
    package var maxResponseBodySize: Int
    /// Called with every response that arrives. Reports it with
    /// ``Vercel/reportFetch(method:host:path:query:statusCode:start:duration:)`` by default.
    package var reportFetch: @Sendable (FetchReport) -> Void

    package init(
        transport: any HTTPTransport = AsyncHTTPClientTransport(),
        maxResponseBodySize: Int = VercelHTTPClient.defaultMaxResponseBodySize,
        reportFetch: @escaping @Sendable (FetchReport) -> Void = FetchReport.send
    ) {
        self.transport = transport
        self.maxResponseBodySize = maxResponseBodySize
        self.reportFetch = reportFetch
    }

    /// Sends `request` and returns the response with its body, whatever its status.
    ///
    /// - Parameter incomingRequestHeaders: The headers of the request being handled that this
    ///   request is made for, when the caller passed them explicitly. They attribute the fetch
    ///   metric to that request outside ``Vercel/withRequest(_:_:)``; inside it, the current
    ///   request is used. Never sent.
    /// - Throws: ``VercelHTTPError`` when no complete response arrives, or `CancellationError`.
    package func send(
        _ request: HTTPRequest,
        body: [UInt8]? = nil,
        timeout: Duration = VercelHTTPClient.defaultTimeout,
        followRedirects: Bool = true,
        incomingRequestHeaders: HTTPFields? = nil
    ) async throws -> VercelHTTPResponse {
        let clock = ContinuousClock()
        let startDate = Date()
        let started = clock.now
        let head: HTTPResponse
        let bytes: [UInt8]
        do {
            (head, bytes) = try await transport.send(
                request,
                body: body,
                timeout: timeout,
                followRedirects: followRedirects,
                maxResponseBodySize: maxResponseBodySize
            )
        } catch {
            throw Self.map(error, request: request, timeout: timeout)
        }
        let duration = clock.now - started

        let (path, query) = request.pathAndQuery
        reportFetch(FetchReport(
            method: request.method.rawValue,
            host: request.authority ?? "",
            path: path,
            query: query,
            statusCode: head.status.code,
            start: startDate,
            duration: duration,
            incomingRequestHeaders: incomingRequestHeaders
        ))

        guard bytes.count <= maxResponseBodySize else {
            throw VercelHTTPError.responseTooLarge(
                method: request.method.rawValue,
                url: request.urlString,
                limit: maxResponseBodySize
            )
        }
        return VercelHTTPResponse(head: head, body: bytes)
    }

    /// Sends a request to `url` and returns the response with its body, whatever its status.
    ///
    /// See ``send(_:body:timeout:followRedirects:incomingRequestHeaders:)`` for
    /// `incomingRequestHeaders`.
    ///
    /// - Throws: ``VercelHTTPError`` when `url` is invalid or no complete response arrives, or
    ///   `CancellationError`.
    package func send(
        _ method: HTTPRequest.Method,
        _ url: String,
        headerFields: HTTPFields = [:],
        body: [UInt8]? = nil,
        timeout: Duration = VercelHTTPClient.defaultTimeout,
        followRedirects: Bool = true,
        incomingRequestHeaders: HTTPFields? = nil
    ) async throws -> VercelHTTPResponse {
        let request = try HTTPRequest(method: method, urlString: url, headerFields: headerFields)
        return try await send(
            request,
            body: body,
            timeout: timeout,
            followRedirects: followRedirects,
            incomingRequestHeaders: incomingRequestHeaders
        )
    }

    static func map(_ error: any Error, request: HTTPRequest, timeout: Duration) -> any Error {
        if error is CancellationError || error is VercelHTTPError {
            return error
        }
        let method = request.method.rawValue
        let url = request.urlString
        if let error = error as? HTTPClientError {
            switch error {
            case .deadlineExceeded, .readTimeout, .writeTimeout, .connectTimeout, .tlsHandshakeTimeout,
                .getConnectionFromPoolTimeout, .socksHandshakeTimeout, .httpProxyHandshakeTimeout:
                return VercelHTTPError.timedOut(method: method, url: url, timeout: timeout)
            case .cancelled where Task.isCancelled:
                return CancellationError()
            default:
                break
            }
        }
        return VercelHTTPError.transport(method: method, url: url, underlying: error)
    }
}

/// An outbound request to report to Vercel Observability (External APIs).
package struct FetchReport: Sendable, Equatable {
    package var method: String
    package var host: String
    package var path: String
    package var query: String?
    package var statusCode: Int
    package var start: Date
    package var duration: Duration
    /// The headers of the request being handled, when the caller passed them explicitly. Used to
    /// find the request to attribute the metric to outside `Vercel.withRequest`.
    package var incomingRequestHeaders: HTTPFields?

    package init(
        method: String,
        host: String,
        path: String,
        query: String?,
        statusCode: Int,
        start: Date,
        duration: Duration,
        incomingRequestHeaders: HTTPFields? = nil
    ) {
        self.method = method
        self.host = host
        self.path = path
        self.query = query
        self.statusCode = statusCode
        self.start = start
        self.duration = duration
        self.incomingRequestHeaders = incomingRequestHeaders
    }

    /// Reports `report` for the current request, or else for the request with
    /// ``incomingRequestHeaders``. Does nothing when neither came through Vercel.
    package static func send(_ report: FetchReport) {
        Vercel.reportFetch(
            method: report.method,
            host: report.host,
            path: report.path,
            query: report.query,
            statusCode: report.statusCode,
            start: report.start,
            duration: report.duration,
            headers: report.incomingRequestHeaders
        )
    }
}

/// A response with its whole body.
package struct VercelHTTPResponse: Sendable {
    /// The status and header fields.
    package var head: HTTPResponse
    /// The body bytes.
    package var body: [UInt8]

    package init(head: HTTPResponse, body: [UInt8]) {
        self.head = head
        self.body = body
    }

    /// The response status.
    package var status: HTTPResponse.Status { head.status }
    /// The response header fields.
    package var headerFields: HTTPFields { head.headerFields }
    /// The body as UTF-8 text, with invalid bytes replaced.
    package var text: String { String(decoding: body, as: UTF8.self) }

    /// Decodes the body as JSON.
    package func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: Data(body))
    }
}

extension HTTPRequest {
    /// A request for an absolute `http` or `https` URL such as
    /// `https://api.example.com/v1/items?id=1`. The URL must already be percent-encoded; see
    /// ``percentEncoded(_:)``. Fragments are dropped.
    ///
    /// - Throws: ``VercelHTTPError/invalidURL(_:)`` without a scheme or host.
    package init(method: Method, urlString: String, headerFields: HTTPFields = [:]) throws(VercelHTTPError) {
        let bytes = Array(urlString.utf8)
        guard let colon = bytes.firstIndex(of: UInt8(ascii: ":")), colon > 0,
            bytes[..<colon].allSatisfy(isSchemeByte),
            bytes[(colon + 1)...].starts(with: [UInt8(ascii: "/"), UInt8(ascii: "/")])
        else { throw .invalidURL(urlString) }
        let rest = bytes[(colon + 3)...].prefix { $0 != UInt8(ascii: "#") }
        let authorityEnd = rest.firstIndex { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "?") } ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        guard !authority.isEmpty, !authority.contains(where: { $0 <= 0x20 || $0 >= 0x7F }) else {
            throw .invalidURL(urlString)
        }
        var path = String(decoding: rest[authorityEnd...], as: UTF8.self)
        if path.isEmpty || path.utf8.first == UInt8(ascii: "?") {
            path = "/" + path
        }
        self.init(
            method: method,
            scheme: String(decoding: bytes[..<colon], as: UTF8.self).lowercased(),
            authority: String(decoding: authority, as: UTF8.self),
            path: path,
            headerFields: headerFields
        )
    }

    /// The absolute URL: `scheme://authority/path?query`.
    package var urlString: String {
        "\(scheme ?? "https")://\(authority ?? "")\(path ?? "/")"
    }

    /// The path without the query, and the query without the leading `?` (`nil` without one).
    package var pathAndQuery: (path: String, query: String?) {
        let full = path ?? "/"
        guard let mark = full.utf8.firstIndex(of: UInt8(ascii: "?")) else { return (full, nil) }
        return (String(full[..<mark]), String(full[full.index(after: mark)...]))
    }
}

private func isSchemeByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
        UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."):
        true
    default:
        false
    }
}
