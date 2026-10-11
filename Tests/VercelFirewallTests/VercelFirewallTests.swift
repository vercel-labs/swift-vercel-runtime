import HTTPTypes
import Synchronization
import Testing
import VercelHTTP
import VercelRuntime
@testable import VercelFirewall

/// Hashes are `printf '%s' '<key><id><VERCEL_AUTOMATION_BYPASS_SECRET><RATE_LIMIT_SECRET>' | shasum -a 256`.
@Suite struct VercelFirewallTests {
    static let production = VercelEnvironment(values: [
        "VERCEL": "1",
        "VERCEL_ENV": "production",
        "VERCEL_AUTOMATION_BYPASS_SECRET": "bypass-secret",
        "RATE_LIMIT_SECRET": "rl-secret",
    ])

    static let requestHeaders = fields([
        ("host", "my-app.vercel.app"),
        ("x-real-ip", "203.0.113.7"),
        ("x-forwarded-for", "203.0.113.7, 10.0.0.1"),
        ("accept", "text/html"),
        ("cookie", "theme=dark; _vercel_jwt=jwt.value.sig"),
        ("cookie", "session=abc"),
        ("x-custom", "a"),
        ("x-custom", "b"),
    ])

    @Test func sendsTheReferenceRequest() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .noContent)])
        let result = try await check("my-api", headers: Self.requestHeaders, timeout: .milliseconds(1500), transport: transport)
        #expect(result == RateLimitResult(rateLimited: false))

        let sent = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(sent.request.method == .get)
        #expect(sent.request.urlString == "https://my-app.vercel.app/.well-known/vercel/rate-limit-api/my-api")
        #expect(sent.body == nil)
        #expect(sent.followRedirects == false)
        #expect(sent.timeout == .milliseconds(1500))
        #expect(pairs(sent.request.headerFields) == [
            ("x-vercel-rate-limit-api", "my-api"),
            ("x-vercel-rate-limit-key", "203.0.113.7-a1a52483cde75d293348afd05dc6e850749054769307053b4f5f05811a827d0c"),
            ("user-agent", "Bot/Vercel Rate Limit Checker"),
            ("x-forwarded-for", "203.0.113.7, 10.0.0.1"),
            ("x-real-ip", "203.0.113.7"),
            ("x-vercel-protection-bypass", "bypass-secret"),
            ("cookie", "_vercel_jwt=jwt.value.sig"),
            ("x-rr-host", "my-app.vercel.app"),
            ("x-rr-x-real-ip", "203.0.113.7"),
            ("x-rr-x-forwarded-for", "203.0.113.7, 10.0.0.1"),
            ("x-rr-accept", "text/html"),
            ("x-rr-cookie", "theme=dark; _vercel_jwt=jwt.value.sig; session=abc"),
            ("x-rr-x-custom", "a, b"),
        ].map(Pair.init))
    }

    @Test func defaultTimeoutWhenNoneIsGiven() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .noContent)])
        _ = try await check("my-api", headers: Self.requestHeaders, transport: transport)
        #expect(transport.requests.first?.timeout == VercelHTTPClient.defaultTimeout)
    }

    @Test func hashesWithoutSecrets() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .noContent)])
        let environment = VercelEnvironment(values: ["VERCEL": "1", "VERCEL_ENV": "preview"])
        _ = try await check("my-api", headers: Self.requestHeaders, environment: environment, transport: transport)
        let fields = try #require(transport.requests.first?.request.headerFields)
        #expect(fields[fieldName("x-vercel-rate-limit-key")] == "203.0.113.7-e9991e09f7a8f28f28337db9c8e9287cadd9a00f9710060418fa54486c9106ef")
        #expect(fields[fieldName("x-vercel-protection-bypass")] == "")
    }

    @Test func hashesWithOnlyTheBypassSecret() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .noContent)])
        let environment = VercelEnvironment(values: ["VERCEL": "1", "VERCEL_AUTOMATION_BYPASS_SECRET": "bypass-secret"])
        _ = try await check("my-api", headers: Self.requestHeaders, environment: environment, transport: transport)
        let fields = try #require(transport.requests.first?.request.headerFields)
        #expect(fields[fieldName("x-vercel-rate-limit-key")] == "203.0.113.7-e9d98832dce93cfcadc971db9ae5825089fb399b630c049834b496fc99be9ed8")
    }

    @Test func customKeyAndEncodedIDAndPathPrefix() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .noContent)])
        let environment = VercelEnvironment(values: ["VERCEL": "1", "PUBLIC_VERCEL_FIREWALL_PATH_PREFIX": "docs"])
        _ = try await check(
            "api/login heavy",
            headers: Self.requestHeaders,
            rateLimitKey: "user:42",
            environment: environment,
            transport: transport
        )
        let sent = try #require(transport.requests.first)
        #expect(sent.request.urlString == "https://my-app.vercel.app/docs/.well-known/vercel/rate-limit-api/api%2Flogin%20heavy")
        #expect(sent.request.headerFields[fieldName("x-vercel-rate-limit-api")] == "api/login heavy")
        #expect(sent.request.headerFields[fieldName("x-vercel-rate-limit-key")] == "user:42-69c61b8b0c5c178ed7e4881be954b3dc87a2dd81d0d340d5e3f2cab069a432a2")
        // The client IP is still forwarded.
        #expect(sent.request.headerFields[fieldName("x-real-ip")] == "203.0.113.7")
    }

    @Test(arguments: [
        (["PUBLIC_VERCEL_FIREWALL_PATH_PREFIX": "/a", "NEXT_PUBLIC_VERCEL_FIREWALL_PATH_PREFIX": "/b"], "/a"),
        (["NEXT_PUBLIC_VERCEL_FIREWALL_PATH_PREFIX": "b/c"], "/b/c"),
        (["PUBLIC_VERCEL_FIREWALL_PATH_PREFIX": "", "NEXT_PUBLIC_VERCEL_FIREWALL_PATH_PREFIX": "/b"], "/b"),
        ([:], ""),
    ])
    func pathPrefix(variables: [String: String], prefix: String) async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .noContent)])
        let environment = VercelEnvironment(values: variables.merging(["VERCEL": "1"]) { $1 })
        _ = try await check("id", headers: Self.requestHeaders, environment: environment, transport: transport)
        #expect(transport.requests.first?.request.urlString == "https://my-app.vercel.app\(prefix)/.well-known/vercel/rate-limit-api/id")
    }

    @Test func forwardsOnlyTheVercelJWTCookie() async throws {
        let cases: [(cookies: [String], expected: String?)] = [
            (["a=1; b=2"], nil),
            (["_vercel_jwt_x=1"], nil),
            (["  _vercel_jwt=one ;b=2", "_vercel_jwt=two"], "_vercel_jwt=two"),
            (["_vercel_jwt="], nil),
            (["_vercel_jwt=a=b"], "_vercel_jwt=a=b"),
            ([], nil),
        ]
        for (cookies, expected) in cases {
            let transport = MockHTTPTransport(responses: [.init(status: .noContent)])
            var headers = fields([("host", "my-app.vercel.app"), ("x-real-ip", "1.2.3.4")])
            for cookie in cookies {
                headers.append(HTTPField(name: .cookie, value: cookie))
            }
            _ = try await check("id", headers: headers, transport: transport)
            let sent = try #require(transport.requests.first)
            #expect(sent.request.headerFields[.cookie] == expected, "cookies: \(cookies)")
        }
    }

    @Test(arguments: [
        (204, RateLimitResult(rateLimited: false)),
        (429, RateLimitResult(rateLimited: true)),
        (403, RateLimitResult(rateLimited: true, reason: .blocked)),
        (404, RateLimitResult(rateLimited: false, reason: .notFound)),
    ])
    func statusMapping(code: Int, expected: RateLimitResult) async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .init(code: code))])
        #expect(try await check("my-api", headers: Self.requestHeaders, transport: transport) == expected)
    }

    @Test(arguments: [500, 200, 302, 401])
    func unexpectedStatusThrows(code: Int) async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .init(code: code))])
        await #expect(throws: VercelFirewallError.unexpectedStatus(statusCode: code)) {
            try await check("my-api", headers: Self.requestHeaders, transport: transport)
        }
    }

    @Test func timeoutThrowsTimedOut() async throws {
        let transport = MockHTTPTransport { request in
            throw VercelHTTPError.timedOut(method: "GET", url: request.request.urlString, timeout: request.timeout)
        }
        await #expect(throws: VercelFirewallError.timedOut(.milliseconds(250))) {
            try await check("my-api", headers: Self.requestHeaders, timeout: .milliseconds(250), transport: transport)
        }
    }

    @Test func transportFailureThrowsRequestFailed() async throws {
        struct Boom: Error {}
        let transport = MockHTTPTransport { _ in throw Boom() }
        let error = await #expect(throws: VercelFirewallError.self) {
            try await check("my-api", headers: Self.requestHeaders, transport: transport)
        }
        guard case .requestFailed(let reason)? = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(reason.hasPrefix("GET https://my-app.vercel.app/.well-known/vercel/rate-limit-api/my-api failed"))
    }

    @Test func invalidHostThrowsRequestFailed() async throws {
        let transport = MockHTTPTransport(responses: [])
        let headers = fields([("host", "bad host"), ("x-real-ip", "1.2.3.4")])
        let error = await #expect(throws: VercelFirewallError.self) {
            try await check("my-api", headers: headers, transport: transport)
        }
        guard case .requestFailed? = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(transport.requests.isEmpty)
    }

    /// Like `encodeURIComponent`: `!*()'` are kept, `/`, spaces and non-ASCII are encoded.
    @Test func encodesTheIDLikeEncodeURIComponent() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .noContent)])
        _ = try await check("a b/(c)!*'~é", headers: Self.requestHeaders, transport: transport)
        #expect(
            transport.requests.first?.request.urlString
                == "https://my-app.vercel.app/.well-known/vercel/rate-limit-api/a%20b%2F(c)!*'~%C3%A9"
        )
        #expect(transport.requests.first?.request.headerFields[fieldName("x-vercel-rate-limit-api")] == "a b/(c)!*'~é")
    }

    @Test func doesNotForwardTheBootstrapToken() {
        let headers = fields([
            ("host", "my-app.vercel.app"),
            ("x-vercel-bootstrap-request", "bootstrap-secret"),
            ("x-vercel-oidc-token", "oidc"),
        ])
        let result = Firewall.rateLimitHeaderFields(id: "i", fullKey: "k", bypassSecret: "", requestHeaders: headers)
        #expect(result[fieldName("x-rr-x-vercel-bootstrap-request")] == nil)
        #expect(!result.contains { $0.value == "bootstrap-secret" })
        // Like Node, other headers, the OIDC token included, are forwarded.
        #expect(result[fieldName("x-rr-host")] == "my-app.vercel.app")
        #expect(result[fieldName("x-rr-x-vercel-oidc-token")] == "oidc")
    }

    @Test func reportsFetchesWithTheExplicitRequestHeaders() async throws {
        let reports = Mutex<[FetchReport]>([])
        let transport = MockHTTPTransport(responses: [.init(status: .noContent), .init(status: .noContent)])
        let client = VercelHTTPClient(transport: transport, reportFetch: { report in reports.withLock { $0.append(report) } })
        _ = try await Firewall.checkRateLimit("my-api", headers: Self.requestHeaders, environment: Self.production, client: client)
        _ = try await Vercel.withRequest(Self.requestHeaders) {
            try await Firewall.checkRateLimit("my-api", environment: Self.production, client: client)
        }
        #expect(reports.withLock { $0.map(\.incomingRequestHeaders) } == [Self.requestHeaders, nil])
        #expect(reports.withLock { $0.first?.path } == "/.well-known/vercel/rate-limit-api/my-api")
    }

    @Test func missingKeyThrows() async throws {
        let transport = MockHTTPTransport(responses: [])
        let headers = fields([("host", "my-app.vercel.app"), ("x-real-ip", "")])
        await #expect(throws: VercelFirewallError.missingRateLimitKey) {
            try await check("my-api", headers: headers, transport: transport)
        }
        await #expect(throws: VercelFirewallError.missingRateLimitKey) {
            try await check("my-api", headers: headers, rateLimitKey: "", transport: transport)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func missingHostThrows() async throws {
        let transport = MockHTTPTransport(responses: [])
        await #expect(throws: VercelFirewallError.missingHost) {
            try await check("my-api", headers: fields([("x-real-ip", "1.2.3.4")]), transport: transport)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func fallsBackToForwardedHost() async throws {
        // Hummingbird and Vapor 5 move `Host` out of the header fields.
        let transport = MockHTTPTransport(responses: [.init(status: .noContent)])
        let headers = fields([("x-forwarded-host", "my-app.vercel.app"), ("x-real-ip", "1.2.3.4")])
        _ = try await check("id", headers: headers, transport: transport)
        #expect(transport.requests.first?.request.urlString == "https://my-app.vercel.app/.well-known/vercel/rate-limit-api/id")
    }

    @Test func missingHeadersThrowsOutsideARequest() async throws {
        let transport = MockHTTPTransport(responses: [])
        await #expect(throws: VercelFirewallError.missingHeaders) {
            try await check("my-api", transport: transport)
        }
    }

    @Test func usesTheCurrentRequestWhenHeadersAreOmitted() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .tooManyRequests)])
        let headers = fields([("host", "current.vercel.app"), ("x-real-ip", "198.51.100.1")])
        let result = try await Vercel.withRequest(headers) {
            try await check("my-api", transport: transport)
        }
        #expect(result == RateLimitResult(rateLimited: true))
        let sent = try #require(transport.requests.first)
        #expect(sent.request.urlString == "https://current.vercel.app/.well-known/vercel/rate-limit-api/my-api")
        #expect(sent.request.headerFields[fieldName("x-rr-host")] == "current.vercel.app")
        #expect(sent.request.headerFields[fieldName("x-real-ip")] == "198.51.100.1")
    }

    @Test func explicitHeadersWinOverTheCurrentRequest() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .noContent)])
        let current = fields([("host", "current.vercel.app"), ("x-real-ip", "198.51.100.1")])
        _ = try await Vercel.withRequest(current) {
            try await check("my-api", headers: Self.requestHeaders, transport: transport)
        }
        #expect(transport.requests.first?.request.authority == "my-app.vercel.app")
    }

    @Test(arguments: [
        VercelEnvironment(values: [:]),
        VercelEnvironment(values: ["VERCEL": "0", "VERCEL_ENV": "production"]),
        VercelEnvironment(values: ["VERCEL": "1", "VERCEL_ENV": "development"]),
    ])
    func developmentWithoutHostReturnsNotLimitedWithoutARequest(environment: VercelEnvironment) async throws {
        let transport = MockHTTPTransport(responses: [])
        // No headers and no key either: development returns before looking at them.
        #expect(try await check("my-api", environment: environment, transport: transport) == RateLimitResult(rateLimited: false))
        #expect(try await check("my-api", firewallHostForDevelopment: "", environment: environment, transport: transport) == RateLimitResult(rateLimited: false))
        #expect(transport.requests.isEmpty)
    }

    @Test func developmentUsesTheDevelopmentHost() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .noContent)])
        let environment = VercelEnvironment(values: ["RATE_LIMIT_SECRET": "rl-secret"])
        let headers = fields([("host", "localhost:8080"), ("x-real-ip", "203.0.113.7")])
        _ = try await check(
            "my-api",
            headers: headers,
            firewallHostForDevelopment: "my-app.vercel.app",
            environment: environment,
            transport: transport
        )
        let sent = try #require(transport.requests.first)
        #expect(sent.request.urlString == "https://my-app.vercel.app/.well-known/vercel/rate-limit-api/my-api")
        #expect(sent.request.headerFields[fieldName("x-rr-host")] == "localhost:8080")
    }

    @Test func developmentIgnoreForTestingUsesTheRequestHost() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .noContent)])
        _ = try await check(
            "my-api",
            headers: Self.requestHeaders,
            firewallHostForDevelopment: "ignore-for-testing",
            environment: VercelEnvironment(values: [:]),
            transport: transport
        )
        #expect(transport.requests.first?.request.authority == "my-app.vercel.app")
    }

    @Test func productionIgnoresTheDevelopmentHost() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .noContent)])
        _ = try await check("my-api", headers: Self.requestHeaders, firewallHostForDevelopment: "other.vercel.app", transport: transport)
        #expect(transport.requests.first?.request.authority == "my-app.vercel.app")
    }

    @Test func copiesSetCookieFieldsSeparately() {
        let headers = fields([("set-cookie", "a=1"), ("set-cookie", "b=2")])
        let result = Firewall.rateLimitHeaderFields(id: "i", fullKey: "k", bypassSecret: "", requestHeaders: headers)
        #expect(result[values: fieldName("x-rr-set-cookie")] == ["a=1", "b=2"])
    }

    @Test func parsesCookiesLikeTheReference() {
        #expect(cookieValue(named: "_vercel_jwt", in: nil) == nil)
        #expect(cookieValue(named: "_vercel_jwt", in: "") == nil)
        #expect(cookieValue(named: "_vercel_jwt", in: "_vercel_jwt") == "")
        #expect(cookieValue(named: "_vercel_jwt", in: "a=1;\t_vercel_jwt=x ; c") == "x")
        #expect(cookieValue(named: "_vercel_jwt", in: "_vercel_jwt=x; _vercel_jwt=y") == "y")
    }

    // MARK: - Helpers

    private func check(
        _ id: String,
        headers: HTTPFields? = nil,
        rateLimitKey: String? = nil,
        timeout: Duration? = nil,
        firewallHostForDevelopment: String? = nil,
        environment: VercelEnvironment = VercelFirewallTests.production,
        transport: MockHTTPTransport
    ) async throws -> RateLimitResult {
        try await Firewall.checkRateLimit(
            id,
            headers: headers,
            rateLimitKey: rateLimitKey,
            timeout: timeout,
            firewallHostForDevelopment: firewallHostForDevelopment,
            environment: environment,
            client: VercelHTTPClient(transport: transport, reportFetch: { _ in })
        )
    }
}

private struct Pair: Equatable, CustomStringConvertible {
    var name: String
    var value: String
    init(_ pair: (String, String)) { (name, value) = pair }
    var description: String { "\(name): \(value)" }
}

private func pairs(_ fields: HTTPFields) -> [Pair] {
    fields.map { Pair(($0.name.canonicalName, $0.value)) }
}

private func fields(_ pairs: [(String, String)]) -> HTTPFields {
    var fields = HTTPFields()
    for (name, value) in pairs {
        fields.append(HTTPField(name: fieldName(name), value: value))
    }
    return fields
}

private func fieldName(_ name: String) -> HTTPField.Name {
    HTTPField.Name(name)!
}
