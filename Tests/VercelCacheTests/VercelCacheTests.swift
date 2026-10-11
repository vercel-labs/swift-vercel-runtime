#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import Synchronization
import Testing
import VercelHTTP
import VercelRuntime
@testable import VercelCache

/// Header field name from a static literal.
private func name(_ name: String) -> HTTPField.Name {
    HTTPField.Name(name)!
}

/// Request headers carrying a Runtime Cache configuration, like Vercel sends them.
private func cacheHeaders(
    host: String = "sc.example.com",
    basePath: String? = nil,
    scheme: String? = nil,
    headers: String = #"{"authorization":"Bearer sc-token","x-vercel-sc-extra":"1"}"#
) -> HTTPFields {
    var fields: HTTPFields = [:]
    fields[name("x-vercel-sc-host")] = host
    if let basePath { fields[name("x-vercel-sc-basepath")] = basePath }
    if let scheme { fields[name("x-vercel-sc-protocol")] = scheme }
    fields[name("x-vercel-sc-headers")] = headers
    return fields
}

private func freshHeaders() -> HTTPFields {
    [name("x-vercel-cache-state"): "fresh"]
}

private struct User: Codable, Equatable {
    var id: Int
    var name: String
}

/// A cache answering from `transport`, for the request with `headers`.
private func makeCache(
    _ transport: MockHTTPTransport,
    namespace: String? = nil,
    headers: HTTPFields? = cacheHeaders(),
    fallback: InMemoryRuntimeCache = InMemoryRuntimeCache(),
    reportFetch: @escaping @Sendable (FetchReport) -> Void = { _ in }
) -> RuntimeCache {
    RuntimeCache(
        namespace: namespace,
        headers: headers,
        client: VercelHTTPClient(transport: transport, reportFetch: reportFetch),
        fallback: fallback
    )
}

/// A settable clock for the in-memory cache.
private final class TestClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var now: @Sendable () -> ContinuousClock.Instant {
        { self.instant.withLock { $0 } }
    }
    func advance(by duration: Duration) {
        instant.withLock { $0 += duration }
    }
}

@Suite struct RuntimeCacheKeyTests {
    /// Expected values from Node: `let h=5381; for (let i=0;i<k.length;i++) h=(h*33)^k.charCodeAt(i);
    /// (h>>>0).toString(16)`.
    @Test(arguments: [
        ("", "1505"),
        ("a", "2b5c4"),
        ("hello", "a9cede7"),
        ("user:1", "6935999f"),
        ("user:42", "8fe8cce8"),
        ("The quick brown fox jumps over the lazy dog", "b679b80a"),
        ("aaaaaaaaaaaaaaaaaaaa", "ba929045"),
        ("\u{0}", "2b5a5"),
        ("caf\u{E9}", "7c70bf28"),
        // Decomposed: hashed by code unit, not by grapheme, like JavaScript.
        ("cafe\u{301}", "a88b725"),
        ("日本語のキー", "bbb5fed"),
        // Emoji are surrogate pairs in UTF-16.
        ("🚀", "50fe18"),
        ("👋🌍", "587aefe2"),
        ("key-🚀-\u{E9}", "2289d8e6"),
        (String(repeating: "x", count: 1000), "1929c505"),
    ])
    func defaultHashMatchesNode(key: String, expected: String) {
        #expect(RuntimeCache.defaultKeyHash(key) == expected)
    }

    @Test func namespace() {
        #expect(RuntimeCache().storageKey(for: "user:1") == "6935999f")
        #expect(RuntimeCache(namespace: "users").storageKey(for: "user:1") == "users$6935999f")
        #expect(RuntimeCache(namespace: "users", namespaceSeparator: ":").storageKey(for: "user:1") == "users:6935999f")
        // Like Node: an empty namespace is none, an empty separator is the default.
        #expect(RuntimeCache(namespace: "").storageKey(for: "user:1") == "6935999f")
        #expect(RuntimeCache(namespace: "users", namespaceSeparator: "").storageKey(for: "user:1") == "users$6935999f")
    }

    @Test func customHashFunction() {
        let cache = RuntimeCache(namespace: "n", keyHashFunction: { "h-\($0)" })
        #expect(cache.storageKey(for: "k") == "n$h-k")
    }

    @Test func pathEncoding() {
        #expect(pathEncoded("users$6935999f") == "users$6935999f")
        #expect(pathEncoded("a/b:c@d") == "a/b:c@d")
        #expect(pathEncoded("a b?c#d\"é") == "a%20b%3Fc%23d%22%C3%A9")
    }

    /// Expected values from Node: `new URL("https://h/v1/suspense-cache/a" + c + "b").pathname`.
    @Test(arguments: [
        ("^", "%5E"), ("%", "%"), ("|", "|"), ("\\", "/"), ("{", "%7B"), ("}", "%7D"), ("\"", "%22"),
        ("`", "%60"), ("<", "%3C"), (">", "%3E"), ("[", "["), ("]", "]"), (" ", "%20"), ("'", "'"),
        ("!$&()*+,;=:@~", "!$&()*+,;=:@~"), ("\u{7F}", "%7F"), ("é", "%C3%A9"),
    ])
    func pathEncodingMatchesNodeURL(character: String, expected: String) {
        #expect(pathEncoded("a\(character)b") == "a\(expected)b")
    }

    @Test(arguments: [
        ("500", Duration?.some(.milliseconds(500))),
        ("1", .milliseconds(1)),
        (" 250ms", .milliseconds(250)),
        ("+42", .milliseconds(42)),
        ("0", nil),
        ("-5", nil),
        ("abc", nil),
        ("", nil),
        ("99999999999999999999999", nil),
    ])
    func timeoutParsing(value: String, expected: Duration?) {
        #expect(RuntimeCache.timeout(milliseconds: value) == expected)
    }

    /// Like JavaScript's `String(n)`, but never in exponent notation.
    @Test(arguments: [
        (Duration.seconds(60), "60"),
        (.milliseconds(1500), "1.5"),
        (.milliseconds(1), "0.001"),
        (.milliseconds(100), "0.1"),
        (.microseconds(1), "0.000001"),
        (.nanoseconds(100), "0.0000001"),
        (.nanoseconds(1), "0.000000001"),
        (.seconds(31_536_000), "31536000"),
        (.seconds(Int64(1e17)) + .milliseconds(500), "100000000000000000"),
        (.seconds(123_456_789) + .milliseconds(123), "123456789.123"),
    ])
    func ttlFormatting(ttl: Duration, expected: String) {
        #expect(RuntimeCacheService.seconds(ttl) == expected)
        #expect(!RuntimeCacheService.seconds(ttl).contains("e"))
    }

    @Test func plainDecimals() {
        #expect(plainDecimal(1e-7) == "0.0000001")
        #expect(plainDecimal(1.25e-10) == "0.000000000125")
        #expect(plainDecimal(1.5e16) == "15000000000000000")
        #expect(plainDecimal(1e21) == "1000000000000000000000")
        #expect(plainDecimal(-2.5e-7) == "-0.00000025")
        #expect(plainDecimal(0.1 + 0.2) == "0.30000000000000004")
        #expect(plainDecimal(42) == "42")
    }
}

@Suite struct RuntimeCacheServiceTests {
    @Test func getSendsTheRequestAndDecodesAFreshValue() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(status: .ok, headerFields: freshHeaders(), body: #"{"id":1,"name":"Ada"}"#),
        ])
        let cache = makeCache(transport, namespace: "users")

        let user = try await cache.get("user:1", as: User.self)

        #expect(user == User(id: 1, name: "Ada"))
        let sent = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(sent.request.method == .get)
        #expect(sent.request.urlString == "https://sc.example.com/v1/suspense-cache/users$6935999f")
        #expect(sent.request.headerFields[name("authorization")] == "Bearer sc-token")
        #expect(sent.request.headerFields[name("x-vercel-sc-extra")] == "1")
        #expect(sent.request.headerFields[name("x-vercel-internal-sc-client-origin")] == "RUNTIME_CACHE")
        #expect(sent.request.headerFields[name("x-vercel-internal-sc-client-name")] == "RUNTIME_CACHE")
        #expect(sent.request.headerFields.count == 4)
        #expect(sent.body == nil)
        #expect(sent.timeout == .milliseconds(500))
    }

    @Test func usesTheBasePathAndProtocol() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .notFound)])
        let cache = makeCache(transport, headers: cacheHeaders(host: "localhost:3000", basePath: "/prefix", scheme: "http"))

        _ = try await cache.get("a", as: String.self)

        #expect(transport.requests.first?.request.urlString == "http://localhost:3000/prefix/v1/suspense-cache/2b5c4")
    }

    @Test func getReturnsNilWhenMissingOrNotFresh() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(status: .notFound, body: "not found"),
            .init(status: .ok, headerFields: [name("x-vercel-cache-state"): "stale"], body: #""old""#),
            .init(status: .ok, headerFields: [name("x-vercel-cache-state"): "expired"], body: #""old""#),
            .init(status: .ok, body: #""no state""#),
        ])
        let cache = makeCache(transport)

        for _ in 0..<4 {
            #expect(try await cache.get("k", as: String.self) == nil)
        }
        #expect(transport.requests.count == 4)
    }

    @Test func getDecodesJSONFragments() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(status: .ok, headerFields: freshHeaders(), body: #""hello""#),
            .init(status: .ok, headerFields: freshHeaders(), body: "42"),
        ])
        let cache = makeCache(transport)

        #expect(try await cache.get("s", as: String.self) == "hello")
        #expect(try await cache.get("n", as: Int.self) == 42)
    }

    @Test func getThrowsOnErrors() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(status: .internalServerError),
            .init(status: .ok, headerFields: freshHeaders(), body: "not json"),
        ])
        let cache = makeCache(transport)

        await #expect(throws: RuntimeCacheError.unexpectedStatus(statusCode: 500, operation: .get)) {
            _ = try await cache.get("k", as: String.self)
        }
        await #expect(throws: DecodingError.self) {
            _ = try await cache.get("k", as: String.self)
        }
    }

    @Test func setSendsTheValueAndOptions() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .ok)])
        let cache = makeCache(transport, namespace: "users")

        try await cache.set("user:1", User(id: 1, name: "Ada/Lovelace"), ttl: .seconds(60), tags: ["users", "team a"])

        let sent = try #require(transport.requests.first)
        #expect(sent.request.method == .post)
        #expect(sent.request.urlString == "https://sc.example.com/v1/suspense-cache/users$6935999f")
        let fields = sent.request.headerFields
        #expect(fields[name("authorization")] == "Bearer sc-token")
        #expect(fields[name("x-vercel-internal-sc-client-origin")] == "RUNTIME_CACHE")
        #expect(fields[name("x-vercel-internal-sc-client-name")] == "RUNTIME_CACHE")
        #expect(fields[name("x-vercel-revalidate")] == "60")
        #expect(fields[name("x-vercel-cache-tags")] == "users,team a")
        // The original key, not the hashed one.
        #expect(fields[name("x-vercel-cache-item-name")] == "user:1")
        let body = try #require(sent.text)
        #expect(body == #"{"id":1,"name":"Ada/Lovelace"}"# || body == #"{"name":"Ada/Lovelace","id":1}"#)
    }

    @Test func setOmitsOptionalHeaders() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .ok), .init(status: .ok), .init(status: .ok)])
        let cache = makeCache(transport)

        try await cache.set("k", "v")
        try await cache.set("k", "v", ttl: .zero, tags: [], name: "")
        try await cache.set("k", "v", ttl: .milliseconds(1500), name: "Readable")

        let requests = transport.requests
        #expect(requests.count == 3)
        #expect(requests[0].request.headerFields[name("x-vercel-revalidate")] == nil)
        #expect(requests[0].request.headerFields[name("x-vercel-cache-tags")] == nil)
        #expect(requests[0].request.headerFields[name("x-vercel-cache-item-name")] == "k")
        #expect(requests[0].text == #""v""#)
        #expect(requests[1].request.headerFields.count == 4)
        #expect(requests[2].request.headerFields[name("x-vercel-revalidate")] == "1.5")
        #expect(requests[2].request.headerFields[name("x-vercel-cache-item-name")] == "Readable")
    }

    @Test func setThrowsUnlessOK() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .created)])
        let cache = makeCache(transport)

        await #expect(throws: RuntimeCacheError.unexpectedStatus(statusCode: 201, operation: .set)) {
            try await cache.set("k", "v")
        }
    }

    @Test func deleteSendsTheRequest() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .ok), .init(status: .notFound)])
        let cache = makeCache(transport, namespace: "users")

        try await cache.delete("user:1")
        await #expect(throws: RuntimeCacheError.unexpectedStatus(statusCode: 404, operation: .delete)) {
            try await cache.delete("user:1")
        }

        let sent = try #require(transport.requests.first)
        #expect(sent.request.method == .delete)
        #expect(sent.request.urlString == "https://sc.example.com/v1/suspense-cache/users$6935999f")
        #expect(sent.request.headerFields[name("x-vercel-internal-sc-client-name")] == "RUNTIME_CACHE")
        #expect(sent.body == nil)
    }

    @Test func expireTagSendsTheTags() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .ok), .init(status: .ok), .init(status: .badRequest)])
        let cache = makeCache(transport, namespace: "users")

        try await cache.expireTag("users")
        try await cache.expireTag(["team a", "a,b/c", "é"])
        // Nothing to expire, no request.
        try await cache.expireTag([])
        await #expect(throws: RuntimeCacheError.unexpectedStatus(statusCode: 400, operation: .expireTag)) {
            try await cache.expireTag("x")
        }

        let requests = transport.requests
        #expect(requests.count == 3)
        #expect(requests[0].request.method == .post)
        #expect(requests[0].request.urlString == "https://sc.example.com/v1/suspense-cache/revalidate?tags=users")
        #expect(requests[0].request.headerFields[name("authorization")] == "Bearer sc-token")
        #expect(requests[0].request.headerFields[name("x-vercel-internal-sc-client-origin")] == "RUNTIME_CACHE")
        #expect(requests[0].body == nil)
        #expect(requests[1].request.urlString == "https://sc.example.com/v1/suspense-cache/revalidate?tags=team%20a,a%2Cb%2Fc,%C3%A9")
    }

    @Test func mapsTimeoutsAndTransportFailures() async throws {
        struct Unreachable: Error {}
        let calls = Mutex(0)
        let transport = MockHTTPTransport { request in
            let call = calls.withLock { count in
                count += 1
                return count
            }
            if call == 1 {
                throw VercelHTTPError.timedOut(method: "GET", url: request.request.urlString, timeout: request.timeout)
            }
            throw Unreachable()
        }
        let cache = RuntimeCache(
            headers: cacheHeaders(),
            client: VercelHTTPClient(transport: transport, reportFetch: { _ in }),
            timeout: .milliseconds(250)
        )

        await #expect(throws: RuntimeCacheError.timedOut(.milliseconds(250), operation: .get)) {
            _ = try await cache.get("k", as: String.self)
        }
        let error = await #expect(throws: RuntimeCacheError.self) {
            try await cache.delete("k")
        }
        guard case .requestFailed(let reason, .delete)? = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(reason.hasPrefix("DELETE https://sc.example.com/v1/suspense-cache/"))
        #expect(error?.operation == .delete)
        #expect(transport.requests.first?.timeout == .milliseconds(250))
    }

    @Test func reportsFetchesWithTheExplicitRequestHeaders() async throws {
        final class Reports: Sendable {
            let all = Mutex<[FetchReport]>([])
        }
        let reports = Reports()
        let transport = MockHTTPTransport(responses: [.init(status: .notFound), .init(status: .notFound)])
        let headers = cacheHeaders()
        let cache = makeCache(transport, headers: headers, reportFetch: { report in reports.all.withLock { $0.append(report) } })
        _ = try await cache.get("a", as: String.self)
        // Inside `withRequest`, without explicit headers, the current request is used instead.
        _ = try await Vercel.withRequest(headers) {
            try await makeCache(transport, headers: nil, reportFetch: { report in reports.all.withLock { $0.append(report) } })
                .get("a", as: String.self)
        }
        #expect(reports.all.withLock { $0.map(\.incomingRequestHeaders) } == [headers, nil])
    }

    @Test func usesTheCurrentRequest() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .notFound)])
        let cache = makeCache(transport, headers: nil)

        _ = try await Vercel.withRequest(cacheHeaders(host: "current.example.com")) {
            try await cache.get("a", as: String.self)
        }

        #expect(transport.requests.first?.request.urlString == "https://current.example.com/v1/suspense-cache/2b5c4")
    }
}

@Suite struct InMemoryFallbackTests {
    @Test func fallsBackWithoutConfiguration() async throws {
        let transport = MockHTTPTransport(responses: [])
        let fallback = InMemoryRuntimeCache()
        let cache = makeCache(transport, namespace: "users", headers: [:], fallback: fallback)

        #expect(try await cache.get("user:1", as: User.self) == nil)
        try await cache.set("user:1", User(id: 1, name: "Ada"), tags: ["users"])
        #expect(try await cache.get("user:1", as: User.self) == User(id: 1, name: "Ada"))
        try await cache.delete("user:1")
        #expect(try await cache.get("user:1", as: User.self) == nil)

        #expect(transport.requests.isEmpty)
        // The warning was logged on first use, and is not logged again.
        #expect(!fallback.shouldWarnUnavailable())
    }

    @Test func fallsBackOutsideARequestAndWithInvalidConfiguration() async throws {
        let transport = MockHTTPTransport(responses: [])
        let fallback = InMemoryRuntimeCache()
        // No headers and no current request.
        try await makeCache(transport, headers: nil, fallback: fallback).set("k", 1)
        // `x-vercel-sc-headers` is not a JSON object of strings.
        let invalid = makeCache(transport, headers: cacheHeaders(headers: "nope"), fallback: fallback)
        #expect(try await invalid.get("k", as: Int.self) == 1)
        #expect(transport.requests.isEmpty)
    }

    @Test func namespacesKeys() async throws {
        let fallback = InMemoryRuntimeCache()
        let transport = MockHTTPTransport(responses: [])
        let users = makeCache(transport, namespace: "users", headers: [:], fallback: fallback)
        let teams = makeCache(transport, namespace: "teams", headers: [:], fallback: fallback)

        try await users.set("1", "user")
        try await teams.set("1", "team")

        #expect(try await users.get("1", as: String.self) == "user")
        #expect(try await teams.get("1", as: String.self) == "team")
    }

    @Test func expiresAfterTheTTL() async throws {
        let clock = TestClock()
        let fallback = InMemoryRuntimeCache(now: clock.now)
        let cache = makeCache(MockHTTPTransport(responses: []), headers: [:], fallback: fallback)

        try await cache.set("short", "a", ttl: .seconds(60))
        try await cache.set("forever", "b")
        try await cache.set("zero", "c", ttl: .zero)

        clock.advance(by: .seconds(60))
        #expect(try await cache.get("short", as: String.self) == "a")
        clock.advance(by: .milliseconds(1))
        #expect(try await cache.get("short", as: String.self) == nil)
        #expect(fallback.count == 2)

        clock.advance(by: .seconds(86_400))
        #expect(try await cache.get("forever", as: String.self) == "b")
        #expect(try await cache.get("zero", as: String.self) == "c")
    }

    /// Like Node's in-memory cache: `lastModified + ttl * 1000 < Date.now()` right away.
    @Test func negativeTTLExpiresImmediately() async throws {
        let clock = TestClock()
        let fallback = InMemoryRuntimeCache(now: clock.now)
        let cache = makeCache(MockHTTPTransport(responses: []), headers: [:], fallback: fallback)

        try await cache.set("gone", "a", ttl: .seconds(-1))
        try await cache.set("barely", "b", ttl: .milliseconds(-1))
        #expect(try await cache.get("gone", as: String.self) == nil)
        #expect(try await cache.get("barely", as: String.self) == nil)
        #expect(fallback.count == 0)
    }

    @Test func expireTagRemovesEntriesWithAnyTag() async throws {
        let fallback = InMemoryRuntimeCache()
        let cache = makeCache(MockHTTPTransport(responses: []), namespace: "n", headers: [:], fallback: fallback)

        try await cache.set("a", 1, tags: ["x"])
        try await cache.set("b", 2, tags: ["y", "z"])
        try await cache.set("c", 3, tags: ["w"])
        try await cache.set("d", 4)

        try await cache.expireTag("x")
        #expect(try await cache.get("a", as: Int.self) == nil)
        #expect(try await cache.get("b", as: Int.self) == 2)

        try await cache.expireTag(["z", "w"])
        #expect(try await cache.get("b", as: Int.self) == nil)
        #expect(try await cache.get("c", as: Int.self) == nil)
        #expect(try await cache.get("d", as: Int.self) == 4)
    }

    @Test func warnsOnce() {
        let fallback = InMemoryRuntimeCache()
        #expect(fallback.shouldWarnUnavailable())
        #expect(!fallback.shouldWarnUnavailable())
        #expect(!fallback.shouldWarnUnavailable())
    }
}

@Suite struct RuntimeCacheValueCodingTests {
    struct Event: Codable, Equatable {
        var name: String
        var at: Date
    }

    /// 2026-10-11T17:00:00.123Z.
    let date = Date(timeIntervalSince1970: 1_791_738_000.123)

    @Test func encodesDatesLikeJavaScript() throws {
        let json = String(decoding: try RuntimeCache.defaultEncoder.encode(Event(name: "a/b", at: date)), as: UTF8.self)
        #expect(json.contains(#""at":"2026-10-11T17:00:00.123Z""#))
        #expect(json.contains(#""name":"a/b""#))
    }

    /// Expected values from Node: `new Date(ms).toJSON()`.
    @Test(arguments: [
        (0.0, "1970-01-01T00:00:00.000Z"),
        (1_791_738_000.1239, "2026-10-11T17:00:00.123Z"),
        (951_782_400.0, "2000-02-29T00:00:00.000Z"),
        (-1.0, "1969-12-31T23:59:59.000Z"),
        (-0.0005, "1969-12-31T23:59:59.999Z"),
        (-62_198_755_200.0, "-000001-01-01T00:00:00.000Z"),
        (253_402_300_800.0, "+010000-01-01T00:00:00.000Z"),
    ])
    func javaScriptDateStrings(seconds: Double, expected: String) {
        #expect(JavaScriptDate.string(from: Date(timeIntervalSince1970: seconds)) == expected)
    }

    @Test func roundTripsThroughTheService() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .ok)])
        let cache = makeCache(transport)
        try await cache.set("event", Event(name: "launch", at: date))
        let stored = try #require(transport.requests.first?.text)
        #expect(stored.contains(#""at":"2026-10-11T17:00:00.123Z""#))

        let reader = makeCache(MockHTTPTransport(responses: [.init(status: .ok, headerFields: freshHeaders(), body: stored)]))
        #expect(try await reader.get("event", as: Event.self) == Event(name: "launch", at: date))
    }

    @Test func roundTripsInMemory() async throws {
        let cache = makeCache(MockHTTPTransport(responses: []), headers: [:])
        try await cache.set("event", Event(name: "launch", at: date))
        #expect(try await cache.get("event", as: Event.self) == Event(name: "launch", at: date))
    }

    /// `JSON.stringify({name: "launch", at: new Date("2026-10-11T17:00:00.123Z")})` in Node, and
    /// timestamps without fractional seconds or with an offset.
    @Test func decodesValuesWrittenByNode() async throws {
        let bodies = [
            #"{"name":"launch","at":"2026-10-11T17:00:00.123Z"}"#,
            #"{"name":"launch","at":"2026-10-11T17:00:00Z"}"#,
            #"{"name":"launch","at":"2026-10-11T19:00:00.123+02:00"}"#,
        ]
        let transport = MockHTTPTransport(responses: bodies.map { .init(status: .ok, headerFields: freshHeaders(), body: $0) })
        let cache = makeCache(transport)
        #expect(try await cache.get("e", as: Event.self) == Event(name: "launch", at: date))
        #expect(try await cache.get("e", as: Event.self) == Event(name: "launch", at: Date(timeIntervalSince1970: 1_791_738_000)))
        #expect(try await cache.get("e", as: Event.self) == Event(name: "launch", at: date))
    }

    @Test func rejectsNonISODates() async throws {
        let transport = MockHTTPTransport(responses: [.init(status: .ok, headerFields: freshHeaders(), body: #"{"name":"x","at":12345}"#)])
        await #expect(throws: DecodingError.self) {
            _ = try await makeCache(transport).get("e", as: Event.self)
        }
    }

    @Test func customEncoderAndDecoder() async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let fallback = InMemoryRuntimeCache()
        let cache = RuntimeCache(
            headers: [:],
            encoder: encoder,
            decoder: decoder,
            client: VercelHTTPClient(transport: MockHTTPTransport(responses: []), reportFetch: { _ in }),
            fallback: fallback
        )
        try await cache.set("e", Event(name: "x", at: Date(timeIntervalSince1970: 10)))
        #expect(fallback.get(cache.storageKey(for: "e")).map { String(decoding: $0, as: UTF8.self) }?.contains(#""at":10"#) == true)
        #expect(try await cache.get("e", as: Event.self)?.at == Date(timeIntervalSince1970: 10))
    }
}

@Suite struct RuntimeCacheRedactionTests {
    @Test func printingACacheDoesNotLeakItsHeaders() {
        var headers = cacheHeaders(headers: #"{"authorization":"Bearer sc-secret"}"#)
        headers[name("cookie")] = "session=cookie-secret"
        headers[name("x-vercel-oidc-token")] = "oidc-secret"
        headers[name("x-vercel-bootstrap-request")] = "bootstrap-secret"
        let cache = RuntimeCache(namespace: "users", headers: headers)

        var dumped = ""
        dump(cache, to: &dumped)
        for output in [String(describing: cache), String(reflecting: cache), "\(cache)", dumped] {
            for secret in ["sc-secret", "cookie-secret", "oidc-secret", "bootstrap-secret", "sc.example.com"] {
                #expect(!output.contains(secret), "\(output)")
            }
            #expect(output.contains("users"))
        }
        #expect(String(describing: RuntimeCache()).contains("headers: nil"))
    }
}
