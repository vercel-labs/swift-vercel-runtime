#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import Synchronization
import VercelHTTP
@testable import VercelOIDC

/// 2026-10-11T16:00:00Z.
let testNow = Date(timeIntervalSince1970: 1_791_734_400)

/// A clock tests can move.
final class TestClock: Sendable {
    private let date: Mutex<Date>

    init(_ date: Date = testNow) {
        self.date = Mutex(date)
    }

    var now: Date { date.withLock { $0 } }

    func advance(by seconds: Double) {
        date.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// An `OIDCClient` over `transport`, with a fixed environment, a test clock and its own cache.
func makeClient(
    _ transport: MockHTTPTransport,
    environment: [String: String] = [:],
    clock: TestClock = TestClock(),
    cache: ExchangeCache = ExchangeCache(),
    reportFetch: @escaping @Sendable (FetchReport) -> Void = { _ in }
) -> OIDCClient {
    OIDCClient(
        http: VercelHTTPClient(transport: transport, reportFetch: reportFetch),
        environment: { environment[$0] },
        now: { clock.now },
        exchangeCache: cache
    )
}

/// Records the fetch metrics a client reports.
final class ReportRecorder: Sendable {
    private let reports = Mutex<[FetchReport]>([])
    var all: [FetchReport] { reports.withLock { $0 } }
    var record: @Sendable (FetchReport) -> Void {
        { report in self.reports.withLock { $0.append(report) } }
    }
}

/// A JWT with `payload` as its claims (the header and signature are fixed placeholders).
func makeJWT(_ payload: String) -> String {
    "\(base64URLEncoded(Array(#"{"alg":"RS256","typ":"JWT"}"#.utf8))).\(base64URLEncoded(Array(payload.utf8))).c2lnbmF0dXJl"
}

/// Base64url without padding.
func base64URLEncoded(_ bytes: [UInt8], padded: Bool = false) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
    var output: [UInt8] = []
    var index = 0
    while index < bytes.count {
        let chunk = bytes[index..<min(index + 3, bytes.count)]
        var value: UInt32 = 0
        for (offset, byte) in chunk.enumerated() {
            value |= UInt32(byte) << UInt32(16 - offset * 8)
        }
        for position in 0...chunk.count {
            output.append(alphabet[Int(value >> UInt32(18 - position * 6) & 0x3F)])
        }
        if padded {
            output.append(contentsOf: repeatElement(UInt8(ascii: "="), count: 3 - chunk.count))
        }
        index += 3
    }
    return String(decoding: output, as: UTF8.self)
}

extension HTTPFields {
    init(_ pairs: [(String, String)]) {
        self.init()
        for (name, value) in pairs {
            append(HTTPField(name: HTTPField.Name(name)!, value: value))
        }
    }
}

/// The JSON object in `body`.
func jsonObject(_ body: [UInt8]?) throws -> [String: String] {
    try JSONDecoder().decode([String: String].self, from: Data(body ?? []))
}

/// The `name=value` pairs of a form body, in order, still percent-encoded.
func formFields(_ text: String?) -> [(String, String)] {
    (text ?? "").split(separator: "&").map { pair in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
    }
}
