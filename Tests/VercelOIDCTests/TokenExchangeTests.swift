#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import Testing
import VercelHTTP
@testable import VercelOIDC

@Suite struct TokenExchangeTests {
    /// 2026-10-11T17:00:00Z: an hour after `testNow`.
    let expiry = 1_791_738_000

    func okResponse(_ token: String, expiry: Int? = nil) -> MockHTTPTransport.Response {
        let body = expiry.map { #"{"token":"\#(token)","expiry":\#($0)}"# } ?? #"{"token":"\#(token)"}"#
        return .init(status: .ok, headerFields: [.contentType: "application/json"], body: body)
    }

    @Test func sendsTheExchangeRequest() async throws {
        let transport = MockHTTPTransport(responses: [okResponse("exchanged", expiry: expiry)])
        let client = makeClient(transport)

        let token = try await client.exchange(token: "source", audience: "https://api.example.com", jti: "id-1", skipCache: false)
        #expect(token == "exchanged")

        let sent = try #require(transport.requests.first)
        #expect(sent.request.method == .post)
        #expect(sent.request.scheme == "https")
        #expect(sent.request.authority == "oidc.vercel.com")
        #expect(sent.request.path == "/~token")
        #expect(sent.request.headerFields[.contentType] == "application/json")
        #expect(sent.request.headerFields[.accept] == "application/json")
        #expect(sent.request.headerFields[.userAgent] == "swift-vercel-runtime/\(VercelLibrary.version)")
        #expect(try jsonObject(sent.body) == ["token": "source", "aud": "https://api.example.com", "jti": "id-1"])
    }

    @Test func omitsMissingAudienceAndEmptyJTI() async throws {
        let transport = MockHTTPTransport(responses: [okResponse("a"), okResponse("b")])
        let client = makeClient(transport)
        _ = try await client.exchange(token: "source", audience: nil, jti: nil, skipCache: false)
        _ = try await client.exchange(token: "source", audience: "aud", jti: "", skipCache: false)
        #expect(try jsonObject(transport.requests[0].body) == ["token": "source"])
        #expect(try jsonObject(transport.requests[1].body) == ["token": "source", "aud": "aud"])
    }

    @Test func cachesUntilExpiry() async throws {
        let transport = MockHTTPTransport(responses: [okResponse("first", expiry: expiry), okResponse("second", expiry: expiry + 3600)])
        let clock = TestClock()
        let client = makeClient(transport, clock: clock)

        #expect(try await client.exchange(token: "source", audience: "aud", jti: nil, skipCache: false) == "first")
        clock.advance(by: 3599)
        #expect(try await client.exchange(token: "source", audience: "aud", jti: nil, skipCache: false) == "first")
        #expect(transport.requests.count == 1)

        // At `expiry` the cached token is no longer used.
        clock.advance(by: 1)
        #expect(try await client.exchange(token: "source", audience: "aud", jti: nil, skipCache: false) == "second")
        #expect(transport.requests.count == 2)
    }

    @Test func cacheKeyIncludesTokenAudienceAndJTI() async throws {
        let transport = MockHTTPTransport { request in
            let body = try jsonObject(request.body)
            let token = "\(body["token"] ?? "")|\(body["aud"] ?? "")|\(body["jti"] ?? "")"
            return .init(status: .ok, body: #"{"token":"\#(token)","expiry":1791738000}"#)
        }
        let client = makeClient(transport)
        let inputs: [(String, String?, String?)] = [
            ("t", "aud", nil), ("t", "aud", "j"), ("t", "other", nil), ("t2", "aud", nil), ("t", nil, nil),
        ]
        for _ in 0..<2 {
            for (token, audience, jti) in inputs {
                let exchanged = try await client.exchange(token: token, audience: audience, jti: jti, skipCache: false)
                #expect(exchanged == "\(token)|\(audience ?? "")|\(jti ?? "")")
            }
        }
        #expect(transport.requests.count == inputs.count)
        #expect(exchangeCacheKey(token: "t", audience: "aud", jti: nil)
            == SHA256.hexDigest(#"["t","aud",null]"#))
    }

    @Test func skipCacheExchangesAgainAndReplacesTheEntry() async throws {
        let transport = MockHTTPTransport(responses: [okResponse("first", expiry: expiry), okResponse("second", expiry: expiry)])
        let client = makeClient(transport)
        #expect(try await client.exchange(token: "source", audience: "aud", jti: nil, skipCache: false) == "first")
        #expect(try await client.exchange(token: "source", audience: "aud", jti: nil, skipCache: true) == "second")
        #expect(try await client.exchange(token: "source", audience: "aud", jti: nil, skipCache: false) == "second")
        #expect(transport.requests.count == 2)
    }

    @Test func missingExpiryUsesTheExchangedTokensExpClaim() async throws {
        let exchanged = makeJWT(#"{"exp":\#(expiry)}"#)
        let transport = MockHTTPTransport(responses: [okResponse(exchanged), okResponse("again")])
        let clock = TestClock()
        let client = makeClient(transport, clock: clock)
        #expect(try await client.exchange(token: "source", audience: "aud", jti: nil, skipCache: false) == exchanged)
        #expect(try await client.exchange(token: "source", audience: "aud", jti: nil, skipCache: false) == exchanged)
        #expect(transport.requests.count == 1)
        clock.advance(by: 3600)
        #expect(try await client.exchange(token: "source", audience: "aud", jti: nil, skipCache: false) == "again")
    }

    @Test func tokensWithoutAFutureExpiryAreNotCached() async throws {
        let transport = MockHTTPTransport(responses: [
            okResponse("opaque"), okResponse("opaque2"),
            okResponse("past", expiry: 1_791_734_400), okResponse("past2", expiry: 1_791_734_400),
        ])
        let client = makeClient(transport)
        #expect(try await client.exchange(token: "a", audience: nil, jti: nil, skipCache: false) == "opaque")
        #expect(try await client.exchange(token: "a", audience: nil, jti: nil, skipCache: false) == "opaque2")
        #expect(try await client.exchange(token: "b", audience: nil, jti: nil, skipCache: false) == "past")
        #expect(try await client.exchange(token: "b", audience: nil, jti: nil, skipCache: false) == "past2")
        #expect(client.exchangeCache.count == 0)
    }

    @Test func errorStatusesThrowWithTheEndpointsMessage() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(status: .forbidden, body: #"{"error":"OIDC is not enabled for this project"}"#),
            .init(status: .badRequest, body: "nope"),
            .init(status: .init(code: 599, reasonPhrase: ""), body: ""),
        ])
        let client = makeClient(transport)
        await #expect(throws: VercelOIDCError.exchangeFailed(statusCode: 403, message: "OIDC is not enabled for this project")) {
            try await client.exchange(token: "t", audience: "a", jti: nil, skipCache: false)
        }
        await #expect(throws: VercelOIDCError.exchangeFailed(statusCode: 400, message: "Bad Request")) {
            try await client.exchange(token: "t", audience: "a", jti: nil, skipCache: false)
        }
        await #expect(throws: VercelOIDCError.exchangeFailed(statusCode: 599, message: "HTTP 599")) {
            try await client.exchange(token: "t", audience: "a", jti: nil, skipCache: false)
        }
    }

    @Test(arguments: [
        ("not json", "response was not valid JSON"),
        (#"{"expiry":1791738000}"#, "response did not contain a token"),
        (#"{"token":42}"#, "response did not contain a token"),
        (#"["token"]"#, "response did not contain a token"),
    ])
    func invalidResponsesThrow(body: String, reason: String) async {
        let client = makeClient(MockHTTPTransport(responses: [.init(status: .ok, body: body)]))
        await #expect(throws: VercelOIDCError.invalidExchangeResponse(reason: reason)) {
            try await client.exchange(token: "t", audience: "a", jti: nil, skipCache: false)
        }
    }

    @Test func transportFailuresBecomeRequestFailed() async {
        struct Unreachable: Error {}
        let client = makeClient(MockHTTPTransport { _ in throw Unreachable() })
        let error = await #expect(throws: VercelOIDCError.self) {
            try await client.exchange(token: "t", audience: "a", jti: nil, skipCache: false)
        }
        guard case .requestFailed(let reason) = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(reason.hasPrefix("POST https://oidc.vercel.com/~token failed"))
        #expect(!reason.contains("\"t\""), "the source token must not appear")
    }

    @Test func timeoutsBecomeTimedOut() async {
        let client = makeClient(MockHTTPTransport { request in
            throw VercelHTTPError.timedOut(method: "POST", url: request.request.urlString, timeout: request.timeout)
        })
        await #expect(throws: VercelOIDCError.timedOut(.seconds(30))) {
            try await client.exchange(token: "t", audience: "a", jti: nil, skipCache: false)
        }
    }

    @Test func concurrentExchangesForTheSameKeyShareOneRequest() async throws {
        let transport = MockHTTPTransport { _ in
            try await Task.sleep(for: .milliseconds(300))
            return .init(status: .ok, body: #"{"token":"shared","expiry":1791738000}"#)
        }
        let client = makeClient(transport)
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<5 {
                // Without the cache too: a call with `skipCache` joins the exchange in flight.
                group.addTask { try await client.exchange(token: "source", audience: "aud", jti: nil, skipCache: index == 4) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(tokens == Array(repeating: "shared", count: 5))
        #expect(transport.requests.count == 1)
        #expect(client.exchangeCache.inFlightCount == 0)

        // Another key gets its own request; a finished exchange is not shared anymore.
        _ = try await client.exchange(token: "source", audience: "other", jti: nil, skipCache: false)
        _ = try await client.exchange(token: "source", audience: "aud", jti: nil, skipCache: true)
        #expect(transport.requests.count == 3)
    }

    @Test func failedSharedExchangesAreNotKept() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .forbidden), okResponse("ok", expiry: expiry)])
        let client = makeClient(transport)
        await #expect(throws: VercelOIDCError.self) {
            try await client.exchange(token: "t", audience: "a", jti: nil, skipCache: false)
        }
        #expect(try await client.exchange(token: "t", audience: "a", jti: nil, skipCache: false) == "ok")
    }

    @Test func reportsFetchesWithTheExplicitRequestHeaders() async throws {
        let reports = ReportRecorder()
        let headers = HTTPFields([("x-vercel-bootstrap-request", "7")])
        let client = makeClient(MockHTTPTransport(responses: [okResponse("x")]), reportFetch: reports.record)
        _ = try await client.exchange(token: "t", audience: "a", jti: nil, skipCache: false, headers: headers)
        #expect(reports.all.map(\.incomingRequestHeaders) == [headers])
        #expect(reports.all.first?.host == "oidc.vercel.com")
    }
}

@Suite struct ExchangeCacheTests {
    let later = testNow.addingTimeInterval(3600)

    @Test func evictsTheLeastRecentlyUsedEntry() {
        let cache = ExchangeCache(maxEntries: 2)
        cache.set("a", token: "A", expiresAt: later)
        cache.set("b", token: "B", expiresAt: later)
        #expect(cache.get("a", now: testNow) == "A") // `a` is now the most recently used.
        cache.set("c", token: "C", expiresAt: later)
        #expect(cache.count == 2)
        #expect(cache.get("b", now: testNow) == nil)
        #expect(cache.get("a", now: testNow) == "A")
        #expect(cache.get("c", now: testNow) == "C")

        // Replacing an entry does not grow the cache.
        cache.set("c", token: "C2", expiresAt: later)
        #expect(cache.count == 2)
        #expect(cache.get("c", now: testNow) == "C2")
    }

    @Test func defaultsToAThousandEntries() {
        let cache = ExchangeCache()
        #expect(cache.maxEntries == 1000)
        for index in 0..<1001 {
            cache.set("key\(index)", token: "\(index)", expiresAt: later)
        }
        #expect(cache.count == 1000)
        #expect(cache.get("key0", now: testNow) == nil)
        #expect(cache.get("key1000", now: testNow) == "1000")
    }

    @Test func expiredEntriesAreDroppedWhenRead() {
        let cache = ExchangeCache()
        cache.set("a", token: "A", expiresAt: later)
        #expect(cache.get("a", now: later.addingTimeInterval(-0.001)) == "A")
        #expect(cache.get("a", now: later) == nil)
        #expect(cache.count == 0)
    }
}
