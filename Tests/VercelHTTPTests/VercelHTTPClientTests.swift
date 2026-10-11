#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import AsyncHTTPClient
import HTTPTypes
import Synchronization
import Testing
@testable import VercelHTTP

@Suite struct VercelHTTPClientTests {
    /// Records the fetch metrics a client reports.
    final class Reports: Sendable {
        private let reports = Mutex<[FetchReport]>([])
        var all: [FetchReport] { reports.withLock { $0 } }
        var record: @Sendable (FetchReport) -> Void {
            { report in self.reports.withLock { $0.append(report) } }
        }
    }

    @Test func sendsTheRequestAndReturnsTheResponse() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(status: .created, headerFields: [.contentType: "application/json"], body: #"{"id":7}"#),
        ])
        let reports = Reports()
        let client = VercelHTTPClient(transport: transport, reportFetch: reports.record)

        let response = try await client.send(
            .post,
            "HTTPS://api.example.com:8443/v1/items?a=1&b=two#fragment",
            headerFields: [.authorization: "Bearer t", .contentType: "application/json"],
            body: Array(#"{"name":"x"}"#.utf8),
            timeout: .milliseconds(500),
            followRedirects: false
        )

        #expect(response.status == .created)
        #expect(response.headerFields[.contentType] == "application/json")
        #expect(response.text == #"{"id":7}"#)
        struct Item: Decodable { var id: Int }
        #expect(try response.decode(Item.self).id == 7)

        let sent = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(sent.request.method == .post)
        #expect(sent.request.scheme == "https")
        #expect(sent.request.authority == "api.example.com:8443")
        #expect(sent.request.path == "/v1/items?a=1&b=two")
        #expect(sent.request.headerFields[.authorization] == "Bearer t")
        #expect(sent.text == #"{"name":"x"}"#)
        #expect(sent.timeout == .milliseconds(500))
        #expect(!sent.followRedirects)

        let report = try #require(reports.all.first)
        #expect(reports.all.count == 1)
        #expect(report.method == "POST")
        #expect(report.host == "api.example.com:8443")
        #expect(report.path == "/v1/items")
        #expect(report.query == "a=1&b=two")
        #expect(report.statusCode == 201)
        #expect(report.duration >= .zero && report.duration < .seconds(5))
        #expect(abs(report.start.timeIntervalSinceNow) < 5)
    }

    @Test func defaults() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .ok)])
        let reports = Reports()
        _ = try await VercelHTTPClient(transport: transport, reportFetch: reports.record).send(.get, "http://localhost")
        let sent = try #require(transport.requests.first)
        #expect(sent.request.path == "/")
        #expect(sent.body == nil)
        #expect(sent.timeout == VercelHTTPClient.defaultTimeout)
        #expect(sent.followRedirects)
        #expect(reports.all.first?.path == "/")
        #expect(reports.all.first?.query == nil)
    }

    @Test func errorStatusesAreResponsesNotErrors() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(status: .notFound, body: "missing"),
            .init(status: .init(code: 503), body: ""),
        ])
        let reports = Reports()
        let client = VercelHTTPClient(transport: transport, reportFetch: reports.record)
        #expect(try await client.send(.get, "https://h/a").status == .notFound)
        #expect(try await client.send(.head, "https://h/b").status.code == 503)
        #expect(reports.all.map(\.statusCode) == [404, 503])
    }

    @Test(arguments: [
        ("https://h", "https", "h", "/"),
        ("https://h?x=1", "https", "h", "/?x=1"),
        ("http://user@h:80/a/b/?c#d", "http", "user@h:80", "/a/b/?c"),
        ("https://[::1]:8080/p", "https", "[::1]:8080", "/p"),
    ])
    func parsesURLs(url: String, scheme: String, authority: String, path: String) throws {
        let request = try HTTPRequest(method: .get, urlString: url)
        #expect(request.scheme == scheme)
        #expect(request.authority == authority)
        #expect(request.path == path)
    }

    @Test(arguments: ["", "example.com/x", "://h/x", "https:/h", "https://", "https:///x", "https://h st/x", "ht tp://h"])
    func rejectsInvalidURLs(url: String) async {
        let transport = MockHTTPTransport(responses: [.init(status: .ok)])
        await #expect {
            _ = try await VercelHTTPClient(transport: transport).send(.get, url)
        } throws: { error in
            guard case .invalidURL(url) = error as? VercelHTTPError else { return false }
            return true
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func capsTheResponseBody() async throws {
        let transport = MockHTTPTransport { request in
            .init(status: .ok, body: [UInt8](repeating: 0x61, count: request.request.path == "/large" ? 11 : 10))
        }
        let client = VercelHTTPClient(transport: transport, maxResponseBodySize: 10, reportFetch: { _ in })
        #expect(try await client.send(.get, "https://h/exact").body.count == 10)
        await #expect {
            _ = try await client.send(.get, "https://h/large")
        } throws: { error in
            guard case .responseTooLarge("GET", "https://h/large", 10) = error as? VercelHTTPError else { return false }
            return true
        }
        #expect(VercelHTTPClient().maxResponseBodySize == 10 * 1024 * 1024)
    }

    @Test func mapsTimeouts() async {
        for timeout in [HTTPClientError.deadlineExceeded, .readTimeout, .connectTimeout, .getConnectionFromPoolTimeout] {
            let reports = Reports()
            let client = VercelHTTPClient(transport: MockHTTPTransport { _ in throw timeout }, reportFetch: reports.record)
            await #expect {
                _ = try await client.send(.get, "https://h/slow", timeout: .milliseconds(250))
            } throws: { error in
                guard case .timedOut("GET", "https://h/slow", .milliseconds(250)) = error as? VercelHTTPError else { return false }
                return "\(error)" == "GET https://h/slow timed out after 250 ms"
            }
            // Only responses are reported.
            #expect(reports.all.isEmpty)
        }
    }

    @Test func wrapsTransportErrors() async {
        struct Unreachable: Error {}
        let client = VercelHTTPClient(transport: MockHTTPTransport { _ in throw Unreachable() }, reportFetch: { _ in })
        await #expect {
            _ = try await client.send(.delete, "https://h/x")
        } throws: { error in
            guard case .transport("DELETE", "https://h/x", let underlying) = error as? VercelHTTPError else { return false }
            return underlying is Unreachable
        }

        // Running out of scripted responses is a transport error too.
        let empty = VercelHTTPClient(transport: MockHTTPTransport(responses: []), reportFetch: { _ in })
        await #expect {
            _ = try await empty.send(.get, "https://h/x")
        } throws: { error in
            guard case .transport(_, _, let underlying) = error as? VercelHTTPError else { return false }
            return underlying is MockHTTPTransport.NoMoreResponses
        }
    }

    @Test func reportsTheIncomingRequestHeaders() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .ok), .init(status: .ok)])
        let reports = Reports()
        let client = VercelHTTPClient(transport: transport, reportFetch: reports.record)
        let incoming: HTTPFields = [HTTPField.Name("x-vercel-bootstrap-request")!: "7"]
        _ = try await client.send(.get, "https://h/a", incomingRequestHeaders: incoming)
        _ = try await client.send(.get, "https://h/b")
        #expect(reports.all.map(\.incomingRequestHeaders) == [incoming, nil])
        // Only reported, never sent.
        #expect(transport.requests.allSatisfy { $0.request.headerFields.isEmpty })
    }

    @Test func errorTimeoutAndRedactedDescriptions() {
        #expect(VercelHTTPError.timedOut(method: "GET", url: "u", timeout: .seconds(2)).timeout == .seconds(2))
        #expect(VercelHTTPError.invalidURL("u").timeout == nil)
        #expect(VercelHTTPError.responseTooLarge(method: "GET", url: "u", limit: 1).timeout == nil)
        let error = VercelHTTPError.timedOut(method: "GET", url: "https://user:secret@h/x", timeout: .milliseconds(1500))
        #expect(error.description == "GET https://<redacted>@h/x timed out after 1500 ms")
    }

    @Test func passesCancellationAndOwnErrorsThrough() async {
        let cancelled = VercelHTTPClient(transport: MockHTTPTransport { _ in throw CancellationError() }, reportFetch: { _ in })
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.send(.get, "https://h/x")
        }
        let tooLarge = VercelHTTPClient(
            transport: MockHTTPTransport { _ in throw VercelHTTPError.responseTooLarge(method: "GET", url: "u", limit: 1) },
            reportFetch: { _ in }
        )
        await #expect {
            _ = try await tooLarge.send(.get, "https://h/x")
        } throws: { error in
            guard case .responseTooLarge("GET", "u", 1) = error as? VercelHTTPError else { return false }
            return true
        }
    }
}
