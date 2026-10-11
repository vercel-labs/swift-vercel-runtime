#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import Synchronization
import Testing
@testable import VercelProtocol
@testable import VercelRuntime

extension Vercel {
    /// Runs `body` with `scope` as the current request's scope, like `withRequest` under the
    /// bootstrap.
    static func withScope<T>(_ scope: RequestScope, headers: HTTPFields = [:], _ body: () throws -> T) rethrows -> T {
        try $currentContext.withValue(RequestContext(headers: headers, scope: scope), operation: body)
    }
}

extension HTTPFields {
    init(_ pairs: [(String, String)]) {
        self.init()
        for (name, value) in pairs {
            append(HTTPField(name: HTTPField.Name(name)!, value: value))
        }
    }
}

@Suite struct RequestContextTests {
    @Test func currentRequestIsNilOutsideWithRequest() {
        #expect(Vercel.currentRequest == nil)
        #expect(Vercel.deadline == nil)
    }

    @Test func withRequestSetsCurrentRequestOffVercel() async {
        let headers = HTTPFields([("x-vercel-id", "iad1::abc"), ("x-vercel-deadline", "2026-10-11T17:00:00.123Z")])
        await Vercel.withRequest(headers) {
            #expect(Vercel.currentRequest?.headers == headers)
            #expect(Vercel.currentRequest?.id == "iad1::abc")
            #expect(Vercel.deadline.map(unixMilliseconds) == 1_791_738_000_123)
            // No bootstrap in tests: there is a request but no scope.
            #expect(Vercel.currentScope == nil)

            let inner = HTTPFields([("x-vercel-id", "inner")])
            await Vercel.withRequest(inner) {
                #expect(Vercel.currentRequest?.id == "inner")
            }
            #expect(Vercel.currentRequest?.id == "iad1::abc")
        }
        #expect(Vercel.currentRequest == nil)
    }

    @Test func withRequestReturnsAndRethrows() async throws {
        struct Failure: Error {}
        #expect(await Vercel.withRequest([:]) { 42 } == 42)
        await #expect(throws: Failure.self) {
            try await Vercel.withRequest([:]) { throw Failure() }
        }
    }

    @Test func reportFetchWithoutAScopeDoesNothing() async {
        Vercel.reportFetch(method: "GET", host: "example.com", path: "/", statusCode: 200, duration: .milliseconds(1))
        await Vercel.withRequest([:]) {
            Vercel.reportFetch(method: "GET", host: "example.com", path: "/", statusCode: 200, duration: .milliseconds(1))
        }
    }

    @Test func millisecondConversions() {
        #expect(unixMilliseconds(Date(timeIntervalSince1970: 1_791_734_674.4959)) == 1_791_734_674_495)
        #expect(unixMilliseconds(Date(timeIntervalSince1970: -5)) == 0)
        #expect(milliseconds(.milliseconds(45)) == 45)
        #expect(milliseconds(.microseconds(45_999)) == 45)
        #expect(milliseconds(.seconds(2) + .nanoseconds(1)) == 2000)
        #expect(milliseconds(.milliseconds(-3)) == 0)
    }
}

@Suite struct DeadlineTests {
    /// Unix milliseconds of a parsed timestamp.
    func parsed(_ value: String) -> UInt64? {
        parseRFC3339(value).map(unixMilliseconds)
    }

    @Test(arguments: [
        ("2026-10-11T17:00:00Z", 1_791_738_000_000),
        ("2026-10-11T17:00:00.123Z", 1_791_738_000_123),
        ("2026-10-11T17:00:00.1Z", 1_791_738_000_100),
        ("2026-10-11T17:00:00.12Z", 1_791_738_000_120),
        // Truncated to milliseconds, like the Python runtime.
        ("2026-10-11T17:00:00.123999999Z", 1_791_738_000_123),
        ("2026-10-11t17:00:00.123z", 1_791_738_000_123),
        ("2026-10-11 17:00:00.123Z", 1_791_738_000_123),
        ("2026-10-11T19:00:00.123+02:00", 1_791_738_000_123),
        ("2026-10-11T12:30:00.123-04:30", 1_791_738_000_123),
        ("2026-10-11T17:00:00+00:00", 1_791_738_000_000),
        ("1970-01-01T00:00:00Z", 0),
        ("2024-02-29T00:00:00Z", 1_709_164_800_000),
        ("2000-03-01T00:00:00Z", 951_868_800_000),
        // AWS STS `Expiration` values (VercelOIDC uses this parser too).
        ("2026-10-11T18:00:00Z", 1_791_741_600_000),
        ("2014-10-24T23:00:23Z", 1_414_191_623_000),
        ("2026-10-11T18:00:00.500Z", 1_791_741_600_500),
    ] as [(String, UInt64)])
    func parsesRFC3339(value: String, expected: UInt64) {
        #expect(parsed(value) == expected)
    }

    @Test(arguments: [
        "", "not a date", "2026-10-11", "2026-10-11T17:00:00", "2026-10-11T17:00Z",
        "2026-10-11T17:00:00.Z", "2026-10-11T17:00:00.123", "2026-10-11T17:00:00+0200",
        "2026-10-11T17:00:00+02", "2026-10-11T17:00:00Z ", " 2026-10-11T17:00:00Z",
        "2026-13-01T00:00:00Z", "2026-00-01T00:00:00Z", "2026-02-29T00:00:00Z", "2026-04-31T00:00:00Z",
        "2026-10-11T24:00:00Z", "2026-10-11T17:60:00Z", "2026-10-11T17:00:61Z",
        // Leap seconds, which Python's `datetime` (the Python runtime) rejects too.
        "2026-10-11T17:00:60Z", "2016-12-31T23:59:60Z",
        "2026-10-11T17:00:00+24:00", "2026-10-11T17:00:00+02:60", "26-10-11T17:00:00Z",
        "2026-1-11T17:00:00Z", "2026-10-11T17:00:00.12a3Z", "2026/10/11T17:00:00Z",
    ])
    func rejectsMalformedTimestamps(value: String) {
        #expect(parseRFC3339(value) == nil)
    }

    /// Before the Unix epoch the milliseconds still count forward from the whole second.
    @Test func parsesTimestampsBefore1970() throws {
        #expect(try #require(parseRFC3339("1969-12-31T23:59:59.500Z")).timeIntervalSince1970 == -0.5)
        #expect(try #require(parseRFC3339("1969-12-31T23:59:59Z")).timeIntervalSince1970 == -1)
        #expect(try #require(parseRFC3339("1900-01-01T00:00:00.001Z")).timeIntervalSince1970 == -2_208_988_799.999)
        #expect(try #require(parseRFC3339("1970-01-01T01:00:00+02:00")).timeIntervalSince1970 == -3600)
    }

    @Test func requestInfoDeadline() {
        #expect(HTTPFields([("x-vercel-deadline", "2026-10-11T17:00:00.123Z")]).vercel.deadline.map(unixMilliseconds) == 1_791_738_000_123)
        #expect(HTTPFields([("x-vercel-deadline", "soon")]).vercel.deadline == nil)
        #expect(HTTPFields().vercel.deadline == nil)
        // Only the public header counts; the bootstrap removes the internal one.
        #expect(HTTPFields([("x-vercel-internal-deadline", "2026-10-11T17:00:00Z")]).vercel.deadline == nil)
    }
}

@Suite struct RuntimeCacheConfigurationTests {
    let fields = [
        "x-vercel-sc-host": "cache.internal",
        "x-vercel-sc-basepath": "/base",
        "x-vercel-sc-protocol": "http",
        "x-vercel-sc-headers": #"{"authorization":"Bearer abc"}"#,
    ]

    @Test func parsesFields() throws {
        let configuration = try #require(RuntimeCacheConfiguration(fields: fields))
        #expect(configuration == RuntimeCacheConfiguration(host: "cache.internal", basePath: "/base", scheme: "http", headers: ["authorization": "Bearer abc"]))
    }

    @Test func defaultsBasePathAndProtocol() throws {
        let configuration = try #require(RuntimeCacheConfiguration(fields: ["x-vercel-sc-host": "h", "x-vercel-sc-headers": "{}"]))
        #expect(configuration.basePath == "")
        #expect(configuration.scheme == "https")
        #expect(configuration.headers == [:])
    }

    @Test func requiresHostAndHeaders() {
        #expect(RuntimeCacheConfiguration(fields: [:]) == nil)
        #expect(RuntimeCacheConfiguration(fields: ["x-vercel-sc-headers": "{}"]) == nil)
        #expect(RuntimeCacheConfiguration(fields: ["x-vercel-sc-host": "", "x-vercel-sc-headers": "{}"]) == nil)
        #expect(RuntimeCacheConfiguration(fields: ["x-vercel-sc-host": "h"]) == nil)
        #expect(RuntimeCacheConfiguration(fields: ["x-vercel-sc-host": "h", "x-vercel-sc-headers": "[]"]) == nil)
        #expect(RuntimeCacheConfiguration(fields: ["x-vercel-sc-host": "h", "x-vercel-sc-headers": "nope"]) == nil)
    }

    /// Like the Python runtime's `str()` coercion: scalars become text, other values are skipped.
    @Test func readsHeaderValuesLeniently() throws {
        let json = #"{"a":"text","n":1,"neg":-2,"f":1.5,"t":true,"no":false,"null":null,"list":["x"],"obj":{"k":"v"}}"#
        let configuration = try #require(RuntimeCacheConfiguration(fields: ["x-vercel-sc-host": "h", "x-vercel-sc-headers": json]))
        #expect(configuration.headers == ["a": "text", "n": "1", "neg": "-2", "f": "1.5", "t": "true", "no": "false"])
    }

    @Test func resolvesFromRequestHeaders() async throws {
        let headers = HTTPFields(fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } + [("accept", "*/*")])
        #expect(await RuntimeCacheConfiguration.fields(headers: headers) == fields)
        #expect(await RuntimeCacheConfiguration.resolve(headers: headers)?.host == "cache.internal")
        // From the current request when no headers are given.
        await Vercel.withRequest(headers) {
            #expect(await RuntimeCacheConfiguration.fields() == fields)
        }
    }

    @Test func nothingOutsideARequestOrOffVercel() async {
        #expect(await RuntimeCacheConfiguration.fields() == [:])
        #expect(await RuntimeCacheConfiguration.resolve() == nil)
        // A bootstrap token without a bootstrap (as in these tests) has nobody to ask.
        let headers = HTTPFields([("x-vercel-bootstrap-request", "7")])
        #expect(await RuntimeCacheConfiguration.fields(headers: headers) == [:])
    }
}
