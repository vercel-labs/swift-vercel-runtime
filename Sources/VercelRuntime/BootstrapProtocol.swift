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
///   fully proxied, `approaching-timeout` shortly before a request's deadline.
/// - app → bootstrap: `log` for a log line attributed to a request, `release` once a finished
///   request has no more `waitUntil` work. The bootstrap sends the runtime's `end` only after
///   `release`.
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

    package var json: String {
        switch self {
        case .ready:
            #"{"type":"ready"}"#
        case .responseFinished(let token):
            #"{"type":"response-finished","token":\#(JSON.string(token))}"#
        case .approachingTimeout(let token):
            #"{"type":"approaching-timeout","token":\#(JSON.string(token))}"#
        }
    }

    package init?(frame: some Collection<UInt8>) {
        guard let decoded = try? JSONDecoder().decode(ProtocolFrame.self, from: Data(frame)) else { return nil }
        switch (decoded.type, decoded.token) {
        case ("ready", _): self = .ready
        case ("response-finished", let token?): self = .responseFinished(token: token)
        case ("approaching-timeout", let token?): self = .approachingTimeout(token: token)
        default: return nil
        }
    }
}

/// Messages from the app to the bootstrap.
package enum AppMessage: Sendable, Equatable {
    /// A log line attributed to the request.
    case log(token: String, message: String, level: IPCMessage.LogLevel)
    /// The request has no more `waitUntil` work.
    case release(token: String)

    package var json: String {
        switch self {
        case .log(let token, let message, let level):
            #"{"type":"log","token":\#(JSON.string(token)),"level":\#(JSON.string(level.rawValue)),"message":\#(JSON.string(message))}"#
        case .release(let token):
            #"{"type":"release","token":\#(JSON.string(token))}"#
        }
    }

    package var isDroppable: Bool {
        if case .log = self { true } else { false }
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
        default:
            return nil
        }
    }
}

private struct ProtocolFrame: Decodable {
    var type: String
    var token: String?
    var message: String?
    var level: String?
}
