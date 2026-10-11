#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The protocol between an app and `VercelBootstrap`, the process that runs it on Vercel.
///
/// The bootstrap owns the connection to the Vercel functions runtime and proxies HTTP to the app.
/// Every proxied request carries an opaque request token in ``requestHeader``. Apps that use
/// ``Vercel/withRequest(_:_:)`` or ``Vercel/waitUntil(for:_:)`` connect to the bootstrap's Unix
/// socket (``socketVariable``) and exchange NUL-terminated JSON frames keyed by that token:
///
/// - bootstrap → app: `ready` once after connecting, `response-finished` when a response has been
///   fully proxied, `approaching-timeout` shortly before a request's deadline, and `runtime-cache`
///   answering the app's `runtime-cache` request.
/// - app → bootstrap: `log` for a log line attributed to a request, `release` once a finished
///   request has no more `waitUntil` work, `fetch-metric` for an outbound HTTP request made while
///   handling a request, and `runtime-cache` to ask for the request's runtime cache configuration
///   (the `x-vercel-sc-*` headers the bootstrap hid from the app). The bootstrap sends the
///   runtime's `end` only after `release`, and always answers `runtime-cache`, with an empty
///   `headers` object for requests it does not know or that have no hidden configuration.
///
/// ```
/// app → bootstrap  {"type":"fetch-metric","token":"1","metric":{"pathname":"/v1/x","search":"a=1","start":1791734674495,"duration":45,"host":"example.com","statusCode":200,"method":"GET","id":1}}
/// app → bootstrap  {"type":"runtime-cache","token":"1"}
/// bootstrap → app  {"type":"runtime-cache","token":"1","headers":{"x-vercel-sc-host":"…"}}
/// ```
///
/// Apps that never connect cost nothing: the bootstrap ends each request when its response is done.
package enum BootstrapProtocol {
    /// Environment variable with the bootstrap's Unix socket path, set for the app process.
    package static let socketVariable = "VERCEL_BOOTSTRAP_SOCKET"
    /// Request header carrying the bootstrap's token for the request. Any value sent by a client
    /// is replaced.
    package static let requestHeader = "x-vercel-bootstrap-request"
}

/// Messages from the bootstrap to the app.
package enum BootstrapMessage: Sendable, Equatable {
    /// Sent once, right after the app connects and is registered.
    case ready
    /// The response for this request has been fully sent.
    case responseFinished(token: String)
    /// The request is about to reach its maximum duration; cancel its background work.
    case approachingTimeout(token: String)
    /// The runtime cache configuration hidden from the app for this request, keyed by lowercased
    /// header name. Empty when the bootstrap has none.
    case runtimeCache(token: String, headers: [String: String])

    package var json: String {
        switch self {
        case .ready:
            #"{"type":"ready"}"#
        case .responseFinished(let token):
            #"{"type":"response-finished","token":\#(JSON.string(token))}"#
        case .approachingTimeout(let token):
            #"{"type":"approaching-timeout","token":\#(JSON.string(token))}"#
        case .runtimeCache(let token, let headers):
            #"{"type":"runtime-cache","token":\#(JSON.string(token)),"headers":\#(JSON.object(headers))}"#
        }
    }

    package init?(frame: some Collection<UInt8>) {
        guard let decoded = try? JSONDecoder().decode(ProtocolFrame.self, from: Data(frame)) else { return nil }
        switch (decoded.type, decoded.token) {
        case ("ready", _): self = .ready
        case ("response-finished", let token?): self = .responseFinished(token: token)
        case ("approaching-timeout", let token?): self = .approachingTimeout(token: token)
        case ("runtime-cache", let token?):
            guard let headers = decoded.headers else { return nil }
            self = .runtimeCache(token: token, headers: headers)
        default: return nil
        }
    }

    /// The token of a `runtime-cache` answer whose `headers` could not be decoded (for example a
    /// non-string value), so the app can stop waiting for that request. `nil` for any other frame,
    /// including well-formed answers.
    package static func undecodableRuntimeCacheToken(frame: some Collection<UInt8>) -> String? {
        guard BootstrapMessage(frame: frame) == nil,
            let decoded = try? JSONDecoder().decode(FrameHeader.self, from: Data(frame)),
            decoded.type == "runtime-cache"
        else { return nil }
        return decoded.token
    }
}

/// Messages from the app to the bootstrap.
package enum AppMessage: Sendable, Equatable {
    /// A log line attributed to the request.
    case log(token: String, message: String, level: IPCMessage.LogLevel)
    /// The request has no more `waitUntil` work.
    case release(token: String)
    /// An outbound HTTP request made while handling the request.
    case fetchMetric(token: String, FetchMetric)
    /// Asks for the request's hidden runtime cache configuration. Always answered with
    /// ``BootstrapMessage/runtimeCache(token:headers:)``.
    case runtimeCache(token: String)

    package var json: String {
        switch self {
        case .log(let token, let message, let level):
            #"{"type":"log","token":\#(JSON.string(token)),"level":\#(JSON.string(level.rawValue)),"message":\#(JSON.string(message))}"#
        case .release(let token):
            #"{"type":"release","token":\#(JSON.string(token))}"#
        case .fetchMetric(let token, let metric):
            #"{"type":"fetch-metric","token":\#(JSON.string(token)),"metric":\#(metric.json)}"#
        case .runtimeCache(let token):
            #"{"type":"runtime-cache","token":\#(JSON.string(token))}"#
        }
    }

    /// Logs and metrics may be dropped when the bootstrap is not reading fast enough.
    package var isDroppable: Bool {
        switch self {
        case .log, .fetchMetric: true
        case .release, .runtimeCache: false
        }
    }

    package init?(frame: some Collection<UInt8>) {
        guard let decoded = try? JSONDecoder().decode(ProtocolFrame.self, from: Data(frame)) else { return nil }
        switch (decoded.type, decoded.token) {
        case ("log", let token?):
            guard let message = decoded.message, let level = decoded.level.flatMap(IPCMessage.LogLevel.init(rawValue:)) else {
                return nil
            }
            self = .log(token: token, message: message, level: level)
        case ("release", let token?):
            self = .release(token: token)
        case ("fetch-metric", let token?):
            guard let metric = decoded.metric else { return nil }
            self = .fetchMetric(token: token, metric)
        case ("runtime-cache", let token?):
            self = .runtimeCache(token: token)
        default:
            return nil
        }
    }
}

/// Just a frame's type and token.
private struct FrameHeader: Decodable {
    var type: String
    var token: String?
}

private struct ProtocolFrame: Decodable {
    var type: String
    var token: String?
    var message: String?
    var level: String?
    var metric: FetchMetric?
    var headers: [String: String]?
}
