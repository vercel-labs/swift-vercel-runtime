import Testing
@testable import VercelGlobalConfig

@Suite struct ConnectionStringTests {
    typealias Connection = GlobalConfig.Connection

    @Test func parsesEdgeConfigScheme() throws {
        let connection = try Connection(connectionString: "edge-config:id=ecfg_abc&token=secret")
        #expect(connection == Connection(type: .vercel, id: "ecfg_abc", baseURL: "https://edge-config.vercel.com/ecfg_abc", token: "secret", version: "1"))
    }

    @Test func decodesEdgeConfigSchemeParametersLikeURLSearchParams() throws {
        let connection = try Connection(connectionString: "edge-config:token=a%2Bb+c%zz&id=ecfg_abc&id=ignored")
        #expect(connection.token == "a+b c%zz")
        #expect(connection.id == "ecfg_abc")
    }

    @Test func parsesVercelURL() throws {
        let connection = try Connection(connectionString: "https://edge-config.vercel.com/ecfg_abc?token=secret")
        #expect(connection == Connection(type: .vercel, id: "ecfg_abc", baseURL: "https://edge-config.vercel.com/ecfg_abc", token: "secret", version: "1"))
    }

    @Test func vercelURLIgnoresVersionAndExtraPath() throws {
        let connection = try Connection(connectionString: "https://Edge-Config.vercel.com:443/ecfg_abc/extra?token=secret&version=7")
        #expect(connection.type == .vercel)
        #expect(connection.id == "ecfg_abc")
        #expect(connection.baseURL == "https://edge-config.vercel.com/ecfg_abc")
        #expect(connection.version == "1")
    }

    @Test func parsesExternalURLWithIDInPath() throws {
        let connection = try Connection(connectionString: "https://config.example.com/ecfg_abc?token=secret&version=2")
        #expect(connection == Connection(type: .external, id: "ecfg_abc", baseURL: "https://config.example.com/ecfg_abc", token: "secret", version: "2"))
    }

    @Test func parsesExternalURLWithIDQuery() throws {
        let connection = try Connection(connectionString: "http://localhost:3000/api/config?id=my-store&token=secret")
        #expect(connection == Connection(type: .external, id: "my-store", baseURL: "http://localhost:3000/api/config", token: "secret", version: "1"))
    }

    @Test func externalPathIDWinsOverQueryID() throws {
        let connection = try Connection(connectionString: "https://config.example.com/ecfg_path?id=query&token=secret")
        #expect(connection.id == "ecfg_path")
    }

    @Test func vercelHostOverHTTPIsExternal() throws {
        let connection = try Connection(connectionString: "http://edge-config.vercel.com/ecfg_abc?token=secret")
        #expect(connection.type == .external)
        #expect(connection.baseURL == "http://edge-config.vercel.com/ecfg_abc")
    }

    @Test func emptyIsMissing() {
        #expect(throws: GlobalConfigError.missingConnectionString) { try Connection(connectionString: "") }
    }

    @Test(arguments: [
        "nonsense",
        "edge-config:id=ecfg_abc",
        "edge-config:token=secret",
        "edge-config:id=&token=secret",
        "https://edge-config.vercel.com/ecfg_abc",
        "https://edge-config.vercel.com/ecfg_abc?token=",
        "https://config.example.com/?token=secret",
        "https://config.example.com?token=secret",
        "https://config.example.com/ecfg_abc?id=x",
        "ecfg_abc",
        "//config.example.com/ecfg_abc?token=secret",
    ])
    func rejectsInvalid(connectionString: String) {
        #expect(throws: GlobalConfigError.invalidConnectionString) { try Connection(connectionString: connectionString) }
    }

    @Test func descriptionHidesToken() throws {
        let connection = try Connection(connectionString: "edge-config:id=ecfg_abc&token=secret")
        #expect(!String(describing: connection).contains("secret"))
        #expect(String(describing: connection).contains("ecfg_abc"))
    }
}
