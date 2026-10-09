#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Identifies one request handled by a function instance.
///
/// Comes from the `x-vercel-internal-invocation-id` and `x-vercel-internal-request-id` headers
/// the Vercel functions runtime adds to every proxied request.
public struct InvocationContext: Sendable, Hashable {
    public var invocationID: String
    /// The multiplexed (N1) request id. The runtime decodes it as a `u32`.
    public var requestID: UInt32?

    public init(invocationID: String, requestID: UInt32?) {
        self.invocationID = invocationID
        self.requestID = requestID
    }

    /// Builds a context from raw header values. Returns `nil` when there is no invocation id,
    /// which means the request did not come through the Vercel functions runtime.
    public init?(invocationID: String?, requestID: String?) {
        guard let invocationID, !invocationID.isEmpty else { return nil }
        self.invocationID = invocationID
        self.requestID = requestID.flatMap { UInt32($0.trimmingSpaces()) }
    }
}

/// Messages sent from a function process to the Vercel functions runtime.
///
/// Each message is a JSON object terminated by a NUL byte on the `VERCEL_IPC_PATH` socket. The
/// runtime decodes them strictly (unknown types or wrongly typed fields are fatal), so this
/// mirrors its schema exactly.
public enum IPCMessage: Sendable, Equatable {
    /// Log levels accepted by the runtime for `log` messages.
    public enum LogLevel: String, Sendable {
        case trace, debug, info, warn, error, fatal
    }

    /// Must be the first message. Tells the runtime which local port to proxy requests to.
    case serverStarted(initDuration: UInt64, httpPort: UInt16)
    /// Sent once per request after the handler and its `waitUntil` work finished. `error` must
    /// be a string or `nil`.
    case end(InvocationContext, error: String? = nil)
    /// A log line attributed to a specific request. The message is base64 encoded on the wire.
    case log(InvocationContext, message: String, level: LogLevel)
    /// Reports a fatal startup failure. Accepted before `serverStarted`.
    case unrecoverableError(exitCode: Int32, message: String)

    /// The JSON encoding of the message, without the NUL terminator.
    public var json: String {
        switch self {
        case .serverStarted(let initDuration, let httpPort):
            return #"{"type":"server-started","payload":{"initDuration":\#(initDuration),"httpPort":\#(httpPort)}}"#
        case .end(let context, let error):
            let errorJSON = error.map(JSON.string) ?? "null"
            return #"{"type":"end","payload":{"context":\#(context.json),"error":\#(errorJSON)}}"#
        case .log(let context, let message, let level):
            let encoded = Base64.encode(Array(message.utf8))
            return #"{"type":"log","payload":{"context":\#(context.json),"message":\#(JSON.string(encoded)),"level":\#(JSON.string(level.rawValue))}}"#
        case .unrecoverableError(let exitCode, let message):
            return #"{"type":"unrecoverable-error","payload":{"exitCode":\#(exitCode),"message":\#(JSON.string(message))}}"#
        }
    }

    /// The bytes written to the socket: JSON followed by a NUL byte.
    public var frame: [UInt8] {
        var bytes = Array(json.utf8)
        bytes.append(0)
        return bytes
    }
}

/// Messages sent from the Vercel functions runtime to the function process.
public enum RuntimeMessage: Sendable, Equatable {
    /// Sent shortly before a request reaches its maximum duration.
    case approachingTimeout(InvocationContext)
    /// A message type this library does not handle.
    case unknown(type: String)

    /// Decodes one NUL-delimited frame, for example
    /// `{"type":"approaching-timeout","context":{"invocationId":"abc","requestId":1}}`.
    public init?(frame: some Collection<UInt8>) {
        guard let decoded = try? JSONDecoder().decode(RuntimeFrame.self, from: Data(frame)) else { return nil }
        switch decoded.type {
        case "approaching-timeout":
            guard let context = decoded.context else { return nil }
            self = .approachingTimeout(InvocationContext(invocationID: context.invocationId, requestID: context.requestId))
        default:
            self = .unknown(type: decoded.type)
        }
    }
}

/// Wire shape of messages from the runtime (serde: internally tagged by `type`).
private struct RuntimeFrame: Decodable {
    struct Context: Decodable {
        var invocationId: String
        var requestId: UInt32?
    }

    var type: String
    var context: Context?
}

extension InvocationContext {
    var json: String {
        let requestIDJSON = requestID.map(String.init) ?? "null"
        return #"{"invocationId":\#(JSON.string(invocationID)),"requestId":\#(requestIDJSON)}"#
    }
}

enum JSON {
    /// Encodes a Swift string as a JSON string literal.
    static func string(_ value: String) -> String {
        // Fast path: base64 log payloads and typical ids need no escaping.
        if !value.utf8.contains(where: { $0 < 0x20 || $0 == UInt8(ascii: "\"") || $0 == UInt8(ascii: "\\") }) {
            return "\"\(value)\""
        }
        var out = "\""
        out.reserveCapacity(value.utf8.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case let scalar where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}

enum Base64 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    /// Standard base64 with padding, as decoded by the runtime.
    static func encode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity((bytes.count + 2) / 3 * 4)
        var index = 0
        while index + 3 <= bytes.count {
            let n = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2])
            out.append(alphabet[Int(n >> 18 & 63)])
            out.append(alphabet[Int(n >> 12 & 63)])
            out.append(alphabet[Int(n >> 6 & 63)])
            out.append(alphabet[Int(n & 63)])
            index += 3
        }
        let remaining = bytes.count - index
        if remaining > 0 {
            var n = UInt32(bytes[index]) << 16
            if remaining == 2 { n |= UInt32(bytes[index + 1]) << 8 }
            out.append(alphabet[Int(n >> 18 & 63)])
            out.append(alphabet[Int(n >> 12 & 63)])
            out.append(remaining == 2 ? alphabet[Int(n >> 6 & 63)] : UInt8(ascii: "="))
            out.append(UInt8(ascii: "="))
        }
        return String(decoding: out, as: UTF8.self)
    }
}

extension String {
    func trimmingSpaces() -> Substring {
        var slice = Substring(self)
        while slice.first == " " { slice.removeFirst() }
        while slice.last == " " { slice.removeLast() }
        return slice
    }
}
