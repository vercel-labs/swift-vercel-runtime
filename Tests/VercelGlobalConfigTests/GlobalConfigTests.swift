#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import Testing
import VercelHTTP
@testable import VercelGlobalConfig

/// A client for `connectionString` whose requests go to a mock transport.
func makeConfig(
    _ connectionString: String = "edge-config:id=ecfg_abc&token=secret",
    environment: [String: String] = [:],
    localDirectory: String = "/nonexistent/edge-config",
    responses: [MockHTTPTransport.Response] = []
) throws -> (GlobalConfig, MockHTTPTransport) {
    let transport = MockHTTPTransport(responses: responses)
    let config = try GlobalConfig(
        connectionString: connectionString,
        environment: environment,
        client: VercelHTTPClient(transport: transport, reportFetch: { _ in }),
        localDirectory: localDirectory
    )
    return (config, transport)
}

let digestField: HTTPFields = [HTTPField.Name("x-edge-config-digest")!: "abc"]

@Suite struct GlobalConfigTests {
    // MARK: Construction

    @Test func fromEnvironmentReadsEdgeConfig() throws {
        let client = VercelHTTPClient(transport: MockHTTPTransport(responses: []), reportFetch: { _ in })
        let config = try GlobalConfig.fromEnvironment(environment: ["EDGE_CONFIG": "edge-config:id=ecfg_env&token=t"], client: client)
        #expect(config.connection.id == "ecfg_env")
        let custom = try GlobalConfig.fromEnvironment("OTHER", environment: ["OTHER": "edge-config:id=ecfg_other&token=t"], client: client)
        #expect(custom.connection.id == "ecfg_other")
    }

    @Test func fromEnvironmentWithoutVariableThrows() {
        let client = VercelHTTPClient(transport: MockHTTPTransport(responses: []), reportFetch: { _ in })
        #expect(throws: GlobalConfigError.missingConnectionString) {
            try GlobalConfig.fromEnvironment(environment: [:], client: client)
        }
        #expect(throws: GlobalConfigError.missingConnectionString) {
            try GlobalConfig.fromEnvironment(environment: ["EDGE_CONFIG": ""], client: client)
        }
        #expect(throws: GlobalConfigError.invalidConnectionString) {
            try GlobalConfig.fromEnvironment(environment: ["EDGE_CONFIG": "nope"], client: client)
        }
    }

    // MARK: Requests

    @Test func getBuildsRequest() async throws {
        let (config, transport) = try makeConfig(responses: [.init(status: .ok, body: "true")])
        #expect(try await config.get("flag", as: Bool.self) == true)

        let sent = try #require(transport.requests.first)
        #expect(sent.request.method == .get)
        #expect(sent.request.urlString == "https://edge-config.vercel.com/ecfg_abc/item/flag?version=1")
        #expect(sent.request.headerFields[.authorization] == "Bearer secret")
        #expect(sent.request.headerFields[HTTPField.Name("x-edge-config-sdk")!] == "swift-vercel-runtime@\(VercelLibrary.version)")
        #expect(sent.request.headerFields[.cacheControl] == "stale-if-error=604800")
        #expect(sent.request.headerFields[HTTPField.Name("x-edge-config-vercel-env")!] == nil)
        #expect(sent.request.headerFields[HTTPField.Name("x-edge-config-min-updated-at")!] == nil)
        #expect(sent.body == nil)
        #expect(sent.timeout == .seconds(10))
    }

    @Test func sendsVercelEnvAndConsistentReadHeaders() async throws {
        let (config, transport) = try makeConfig(environment: ["VERCEL_ENV": "preview"], responses: [.init(status: .ok, body: "1")])
        #expect(try await config.get("count", as: Int.self, consistentRead: true) == 1)

        let fields = try #require(transport.requests.first).request.headerFields
        #expect(fields[HTTPField.Name("x-edge-config-vercel-env")!] == "preview")
        #expect(fields[HTTPField.Name("x-edge-config-min-updated-at")!] == "9007199254740991")
    }

    @Test func encodesKeyAndUsesExternalBaseURLAndVersion() async throws {
        var (config, transport) = try makeConfig(
            "https://config.example.com/stores/ecfg_x?token=t&version=2%201",
            responses: [.init(status: .ok, body: #""v""#)]
        )
        config.timeout = .milliseconds(250)
        #expect(try await config.get("a b/c?d", as: String.self) == "v")
        let sent = try #require(transport.requests.first)
        #expect(sent.request.urlString == "https://config.example.com/stores/ecfg_x/item/a%20b%2Fc%3Fd?version=2%201")
        #expect(sent.timeout == .milliseconds(250))
    }

    // MARK: get

    @Test func getDecodesTypedAndUntypedValues() async throws {
        struct Banner: Decodable, Equatable {
            var enabled: Bool
            var text: String
        }
        let body = #"{"enabled":true,"text":"Hi","ratio":0.5,"tags":["a",null]}"#
        let (config, _) = try makeConfig(responses: [.init(status: .ok, body: body), .init(status: .ok, body: body)])

        #expect(try await config.get("banner", as: Banner.self) == Banner(enabled: true, text: "Hi"))
        let value = try #require(try await config.get("banner"))
        #expect(value == ["enabled": true, "text": "Hi", "ratio": 0.5, "tags": ["a", .null]])
        #expect(value["enabled"]?.boolValue == true)
        #expect(value["tags"]?[1]?.isNull == true)
    }

    @Test func getTypeFromContext() async throws {
        let (config, _) = try makeConfig(responses: [.init(status: .ok, body: #"{"/old":"/new"}"#)])
        let redirects: [String: String]? = try await config.get("redirects")
        #expect(redirects == ["/old": "/new"])
    }

    @Test func getMissingKeyIsNil() async throws {
        let (config, _) = try makeConfig(responses: [.init(status: .notFound, headerFields: digestField)])
        #expect(try await config.get("missing", as: String.self) == nil)
    }

    @Test func getMissingStoreThrows() async throws {
        let (config, _) = try makeConfig(responses: [.init(status: .notFound)])
        await #expect(throws: GlobalConfigError.storeNotFound) { try await config.get("key") }
    }

    @Test func getUnauthorizedThrows() async throws {
        let (config, _) = try makeConfig(responses: [.init(status: .unauthorized, headerFields: digestField)])
        await #expect(throws: GlobalConfigError.unauthorized) { try await config.get("key") }
    }

    @Test func getUnexpectedStatusThrows() async throws {
        let (config, _) = try makeConfig(responses: [.init(status: .internalServerError)])
        await #expect(throws: GlobalConfigError.unexpectedStatus(statusCode: 500)) { try await config.get("key") }
    }

    @Test func getEmptyKeyIsNilWithoutRequest() async throws {
        let (config, transport) = try makeConfig()
        #expect(try await config.get("") == nil)
        #expect(try await config.get(" \t", as: String.self) == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test func getWrongTypeThrowsDecodingError() async throws {
        let (config, _) = try makeConfig(responses: [.init(status: .ok, body: #""text""#)])
        await #expect(throws: DecodingError.self) { try await config.get("key", as: Int.self) }
    }

    // MARK: has

    @Test func hasUsesHead() async throws {
        let (config, transport) = try makeConfig(responses: [.init(status: .ok)])
        #expect(try await config.has("flag", consistentRead: true))
        let sent = try #require(transport.requests.first)
        #expect(sent.request.method == .head)
        #expect(sent.request.urlString == "https://edge-config.vercel.com/ecfg_abc/item/flag?version=1")
        #expect(sent.request.headerFields[HTTPField.Name("x-edge-config-min-updated-at")!] == "9007199254740991")
    }

    @Test func hasStatuses() async throws {
        let (config, _) = try makeConfig(responses: [
            .init(status: .notFound, headerFields: digestField),
            .init(status: .notFound),
            .init(status: .unauthorized),
            .init(status: .serviceUnavailable),
        ])
        #expect(try await config.has("missing") == false)
        await #expect(throws: GlobalConfigError.storeNotFound) { try await config.has("key") }
        await #expect(throws: GlobalConfigError.unauthorized) { try await config.has("key") }
        await #expect(throws: GlobalConfigError.unexpectedStatus(statusCode: 503)) { try await config.has("key") }
    }

    @Test func hasEmptyKeyIsFalseWithoutRequest() async throws {
        let (config, transport) = try makeConfig()
        #expect(try await config.has("  ") == false)
        #expect(transport.requests.isEmpty)
    }

    // MARK: getAll

    @Test func getAllWithoutKeys() async throws {
        let (config, transport) = try makeConfig(responses: [.init(status: .ok, body: #"{"a":1,"b":"two"}"#)])
        #expect(try await config.getAll() == ["a": 1, "b": "two"])
        let sent = try #require(transport.requests.first)
        #expect(sent.request.method == .get)
        #expect(sent.request.urlString == "https://edge-config.vercel.com/ecfg_abc/items?version=1")
    }

    @Test func getAllWithKeysSkipsEmptyAndEncodes() async throws {
        struct Flags: Decodable, Equatable {
            var newCheckout: Bool?
            var maintenance: Bool?
        }
        let (config, transport) = try makeConfig(responses: [.init(status: .ok, body: #"{"newCheckout":true}"#)])
        let flags = try await config.getAll(keys: ["newCheckout", "", " ", "a b&c"], as: Flags.self)
        #expect(flags == Flags(newCheckout: true, maintenance: nil))
        let sent = try #require(transport.requests.first)
        #expect(sent.request.urlString == "https://edge-config.vercel.com/ecfg_abc/items?version=1&key=newCheckout&key=a%20b%26c")
    }

    @Test func getAllWithNoUsableKeysSkipsRequest() async throws {
        let (config, transport) = try makeConfig()
        #expect(try await config.getAll(keys: []) == [:])
        #expect(try await config.getAll(keys: ["", "  "]) == [:])
        #expect(transport.requests.isEmpty)
    }

    @Test func getAllStatuses() async throws {
        let (config, _) = try makeConfig(responses: [
            .init(status: .unauthorized),
            .init(status: .notFound, headerFields: digestField),
            .init(status: .badGateway),
        ])
        await #expect(throws: GlobalConfigError.unauthorized) { try await config.getAll() }
        await #expect(throws: GlobalConfigError.storeNotFound) { try await config.getAll(keys: ["a"]) }
        await #expect(throws: GlobalConfigError.unexpectedStatus(statusCode: 502)) { try await config.getAll() }
    }

    // MARK: digest

    @Test func digestRequest() async throws {
        let (config, transport) = try makeConfig(responses: [.init(status: .ok, body: #""a1b2""#), .init(status: .internalServerError)])
        #expect(try await config.digest() == "a1b2")
        let sent = try #require(transport.requests.first)
        #expect(sent.request.urlString == "https://edge-config.vercel.com/ecfg_abc/digest?version=1")
        await #expect(throws: GlobalConfigError.unexpectedStatus(statusCode: 500)) { try await config.digest() }
    }
}

@Suite struct GlobalConfigErrorMappingTests {
    func makeConfig(_ handler: @escaping @Sendable (MockHTTPTransport.Request) async throws -> MockHTTPTransport.Response) throws -> GlobalConfig {
        try GlobalConfig(
            connectionString: "edge-config:id=ecfg_abc&token=secret-token",
            timeout: .milliseconds(250),
            environment: [:],
            client: VercelHTTPClient(transport: MockHTTPTransport(handler), reportFetch: { _ in }),
            localDirectory: "/nonexistent/edge-config"
        )
    }

    @Test func timeoutsBecomeTimedOut() async throws {
        let config = try makeConfig { request in
            throw VercelHTTPError.timedOut(method: "GET", url: request.request.urlString, timeout: request.timeout)
        }
        await #expect(throws: GlobalConfigError.timedOut(.milliseconds(250))) { try await config.get("key") }
        await #expect(throws: GlobalConfigError.timedOut(.milliseconds(250))) { try await config.has("key") }
        await #expect(throws: GlobalConfigError.timedOut(.milliseconds(250))) { try await config.getAll() }
        await #expect(throws: GlobalConfigError.timedOut(.milliseconds(250))) { try await config.digest() }
    }

    @Test func transportFailuresBecomeRequestFailedWithoutTheToken() async throws {
        struct Unreachable: Error {}
        let config = try makeConfig { _ in throw Unreachable() }
        let error = await #expect(throws: GlobalConfigError.self) { try await config.get("key") }
        guard case .requestFailed(let reason)? = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(reason.hasPrefix("GET https://edge-config.vercel.com/ecfg_abc/item/key?version=1 failed"))
        #expect(!reason.contains("secret-token"))
        #expect(!String(describing: error).contains("secret-token"))
    }

    @Test func externalURLCredentialsAreRedactedInErrors() async throws {
        struct Unreachable: Error {}
        let config = try GlobalConfig(
            connectionString: "https://user:pass-secret@example.com/ecfg_x?token=secret-token",
            environment: [:],
            client: VercelHTTPClient(transport: MockHTTPTransport { _ in throw Unreachable() }, reportFetch: { _ in })
        )
        let error = await #expect(throws: GlobalConfigError.self) { try await config.digest() }
        let text = String(describing: error)
        #expect(text.contains("https://<redacted>@example.com/ecfg_x/digest"))
        #expect(!text.contains("pass-secret"))
    }
}

@Suite struct GlobalConfigRedactionTests {
    func outputs(_ value: Any) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), "\(value)", dumped]
    }

    @Test func printingAClientDoesNotLeakTheToken() throws {
        let (config, _) = try makeConfig("edge-config:id=ecfg_abc&token=secret-token", environment: ["VERCEL_ENV": "production"])
        for output in outputs(config) + outputs(config.connection) {
            #expect(!output.contains("secret-token"), "\(output)")
            #expect(!output.contains("Bearer"), "\(output)")
            #expect(output.contains("ecfg_abc"), "\(output)")
        }
        // The token is still there for those who ask for it.
        #expect(config.connection.token == "secret-token")
    }

    @Test func printingAnExternalConnectionRedactsURLCredentials() throws {
        let connection = try GlobalConfig.Connection(connectionString: "https://user:pass-secret@example.com/ecfg_x?token=secret-token")
        for output in outputs(connection) {
            #expect(!output.contains("secret-token"), "\(output)")
            #expect(!output.contains("pass-secret"), "\(output)")
            #expect(output.contains("example.com"), "\(output)")
        }
    }
}
