import AsyncHTTPClient
import HTTPTypes
import NIOCore
import NIOHTTP1

/// The default ``HTTPTransport``: AsyncHTTPClient's shared client.
///
/// Requests that follow redirects use `HTTPClient.shared`. Requests that must not follow them use a
/// second process-wide client configured to return `3xx` responses, since AsyncHTTPClient
/// configures redirects per client.
package struct AsyncHTTPClientTransport: HTTPTransport {
    package init() {}

    package func send(
        _ request: HTTPRequest,
        body: [UInt8]?,
        timeout: Duration,
        followRedirects: Bool,
        maxResponseBodySize: Int
    ) async throws -> (HTTPResponse, [UInt8]) {
        let url = request.urlString
        var clientRequest = HTTPClientRequest(url: url)
        clientRequest.method = HTTPMethod(rawValue: request.method.rawValue)
        for field in request.headerFields {
            clientRequest.headers.add(name: field.name.rawName, value: field.value)
        }
        if let body {
            clientRequest.body = .bytes(body)
        }

        let client = followRedirects ? HTTPClient.shared : nonRedirectingClient
        // The deadline covers the body too: AsyncHTTPClient cancels the request when it passes.
        let deadline = NIODeadline.now() + .nanoseconds(nanoseconds(timeout))
        let response = try await client.execute(clientRequest, deadline: deadline)

        var bytes: [UInt8] = []
        for try await buffer in response.body {
            guard bytes.count + buffer.readableBytes <= maxResponseBodySize else {
                throw VercelHTTPError.responseTooLarge(method: request.method.rawValue, url: url, limit: maxResponseBodySize)
            }
            bytes.append(contentsOf: buffer.readableBytesView)
        }

        var headerFields = HTTPFields()
        for (name, value) in response.headers {
            if let fieldName = HTTPField.Name(name) {
                headerFields.append(HTTPField(name: fieldName, value: value))
            }
        }
        let status = HTTPResponse.Status(code: Int(response.status.code), reasonPhrase: response.status.reasonPhrase)
        return (HTTPResponse(status: status, headerFields: headerFields), bytes)
    }
}

/// Like `HTTPClient.shared`, but returns redirects instead of following them. Never shut down: it
/// lives as long as the process.
private let nonRedirectingClient: HTTPClient = {
    var configuration = HTTPClient.Configuration.singletonConfiguration
    configuration.redirectConfiguration = .disallow
    return HTTPClient(eventLoopGroup: HTTPClient.defaultEventLoopGroup, configuration: configuration)
}()

private func nanoseconds(_ duration: Duration) -> Int64 {
    let (seconds, attoseconds) = duration.components
    let (product, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !overflow else { return seconds < 0 ? 0 : .max }
    return max(0, product + attoseconds / 1_000_000_000)
}
