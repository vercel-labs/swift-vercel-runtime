#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import Testing
import VercelHTTP
@testable import VercelGlobalConfig

/// The deployment snapshot fast path (`/opt/edge-config/<id>.json`). Every test uses its own
/// directory because snapshots are cached per path for the life of the process.
@Suite struct LocalFileTests {
    static let snapshot = #"""
        {"digest":"local-digest","updatedAt":1700000000000,
         "items":{"flag":true,"count":3,"banner":{"enabled":true,"text":"Hi"},"nothing":null}}
        """#
    static let lambda = ["AWS_LAMBDA_FUNCTION_NAME": "fn"]

    /// A fresh directory containing `<id>.json` with `contents`.
    func directory(id: String = "ecfg_abc", contents: String? = snapshot) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let contents {
            try Data(contents.utf8).write(to: directory.appendingPathComponent("\(id).json"))
        }
        return directory.path
    }

    @Test func servesReadsFromSnapshot() async throws {
        struct Banner: Decodable, Equatable {
            var enabled: Bool
            var text: String
        }
        let (config, transport) = try makeConfig(environment: Self.lambda, localDirectory: try directory())

        #expect(try await config.get("flag", as: Bool.self) == true)
        #expect(try await config.get("count", as: Int.self) == 3)
        #expect(try await config.get("banner", as: Banner.self) == Banner(enabled: true, text: "Hi"))
        #expect(try await config.get("nothing") == .null)
        #expect(try await config.get("missing") == nil)
        #expect(try await config.get(" ") == nil)
        #expect(try await config.has("flag"))
        #expect(try await config.has("nothing"))
        #expect(try await config.has("missing") == false)
        #expect(try await config.getAll().keys.sorted() == ["banner", "count", "flag", "nothing"])
        #expect(try await config.getAll(keys: ["flag", "missing"]) == ["flag": true])
        #expect(try await config.getAll(keys: []) == [:])
        #expect(try await config.digest() == "local-digest")
        #expect(transport.requests.isEmpty)
    }

    @Test func consistentReadSkipsSnapshot() async throws {
        let (config, transport) = try makeConfig(
            environment: Self.lambda,
            localDirectory: try directory(),
            responses: [.init(status: .ok, body: "false")]
        )
        #expect(try await config.get("flag", as: Bool.self, consistentRead: true) == false)
        #expect(transport.requests.count == 1)
    }

    @Test func readsSnapshotOncePerProcess() async throws {
        let path = try directory()
        let (config, _) = try makeConfig(environment: Self.lambda, localDirectory: path)
        #expect(try await config.digest() == "local-digest")

        try FileManager.default.removeItem(atPath: "\(path)/ecfg_abc.json")
        let (other, transport) = try makeConfig(environment: Self.lambda, localDirectory: path)
        #expect(try await other.digest() == "local-digest")
        #expect(transport.requests.isEmpty)
    }

    @Test func ignoredOutsideFunctions() async throws {
        let (config, transport) = try makeConfig(
            environment: ["AWS_LAMBDA_FUNCTION_NAME": ""],
            localDirectory: try directory(),
            responses: [.init(status: .ok, body: #""remote""#)]
        )
        #expect(try await config.digest() == "remote")
        #expect(transport.requests.count == 1)
    }

    @Test func ignoredForExternalStores() async throws {
        let (config, transport) = try makeConfig(
            "https://config.example.com/ecfg_abc?token=t",
            environment: Self.lambda,
            localDirectory: try directory(),
            responses: [.init(status: .ok, body: #""remote""#)]
        )
        #expect(try await config.digest() == "remote")
        #expect(transport.requests.first?.request.urlString == "https://config.example.com/ecfg_abc/digest?version=1")
    }

    @Test func missingOrMalformedSnapshotFallsBackToHTTP() async throws {
        let (missing, missingTransport) = try makeConfig(
            environment: Self.lambda,
            localDirectory: try directory(contents: nil),
            responses: [.init(status: .ok, body: "true")]
        )
        #expect(try await missing.get("flag", as: Bool.self) == true)
        #expect(missingTransport.requests.count == 1)

        let (malformed, malformedTransport) = try makeConfig(
            environment: Self.lambda,
            localDirectory: try directory(contents: "{not json"),
            responses: [.init(status: .ok, body: "true")]
        )
        #expect(try await malformed.has("flag"))
        #expect(malformedTransport.requests.first?.request.method == .head)
    }

    @Test func snapshotFileIsNamedAfterStoreID() async throws {
        let (config, transport) = try makeConfig(
            "edge-config:id=ecfg_other&token=t",
            environment: Self.lambda,
            localDirectory: try directory(id: "ecfg_abc"),
            responses: [.init(status: .ok, body: #""remote""#)]
        )
        #expect(try await config.digest() == "remote")
        #expect(transport.requests.count == 1)
    }
}
