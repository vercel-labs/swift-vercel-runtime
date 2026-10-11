#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Logging
import VercelProtocol

/// A swift-log handler that attributes logs to the request that produced them.
///
/// Inside ``Vercel/withRequest(_:_:)`` (or ``Vercel/waitUntil(for:_:)`` work) on Vercel, each log
/// is sent with its level and the request it belongs to, so it shows up under that request in
/// Vercel's logs, even with many concurrent requests. Everywhere else (startup, other code, local
/// development) it writes a line to standard output, or standard error for `error` and above,
/// which Vercel also collects.
///
/// It is optional: without it, logs still reach Vercel through standard output and error, just not
/// tied to a request. Install it once, before creating your application:
///
/// ```swift
/// VercelLogHandler.bootstrap()
/// ```
///
/// swift-log can only be bootstrapped once per process. If your app already calls
/// `LoggingSystem.bootstrap`, add this handler to that call with `MultiplexLogHandler` instead of
/// calling ``bootstrap(logLevel:metadataProvider:)`` too:
///
/// ```swift
/// LoggingSystem.bootstrap { label in
///     MultiplexLogHandler([
///         VercelLogHandler(label: label),
///         MyServiceLogHandler(label: label),
///     ])
/// }
/// ```
///
/// It writes to standard output itself outside requests, so use it instead of swift-log's
/// `StreamLogHandler`, not alongside it.
public struct VercelLogHandler: LogHandler {
    public var metadata: Logger.Metadata = [:]
    public var metadataProvider: Logger.MetadataProvider?
    public var logLevel: Logger.Level
    public let label: String

    public init(
        label: String,
        logLevel: Logger.Level? = nil,
        metadataProvider: Logger.MetadataProvider? = nil
    ) {
        self.label = label
        self.logLevel = logLevel ?? Self.defaultLogLevel
        self.metadataProvider = metadataProvider
    }

    /// Installs `VercelLogHandler` as the process-wide swift-log backend.
    ///
    /// swift-log can only be bootstrapped once per process, so call this at most once, at the very
    /// start of `main`, and not if your app calls `LoggingSystem.bootstrap` itself (combine the
    /// handlers with `MultiplexLogHandler` there instead). The level defaults to the `LOG_LEVEL`
    /// environment variable, or `info`.
    public static func bootstrap(logLevel: Logger.Level? = nil, metadataProvider: Logger.MetadataProvider? = nil) {
        LoggingSystem.bootstrap({ label, provider in
            VercelLogHandler(label: label, logLevel: logLevel, metadataProvider: provider)
        }, metadataProvider: metadataProvider)
    }

    /// The level from the `LOG_LEVEL` environment variable, or `info`.
    public static var defaultLogLevel: Logger.Level {
        environmentValue("LOG_LEVEL").flatMap { Logger.Level(rawValue: $0.lowercased()) } ?? .info
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        var merged = metadata
        if let provider = metadataProvider {
            merged.merge(provider.get()) { _, new in new }
        }
        if let eventMetadata = event.metadata {
            merged.merge(eventMetadata) { _, new in new }
        }
        if let error = event.error {
            merged["error"] = "\(error)"
        }
        let text = Self.render(message: event.message.description, metadata: merged)

        if let scope = Vercel.currentScope {
            // Vercel adds the timestamp and shows the level, so the message stays bare.
            scope.client.log(text, level: IPCMessage.LogLevel(event.level), token: scope.token)
            return
        }

        writeLine("\(timestamp()) \(event.level) \(label): \(text)", to: event.level >= .error ? 2 : 1)
    }

    static func render(message: String, metadata: Logger.Metadata) -> String {
        guard !metadata.isEmpty else { return message }
        let rendered = metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "\(message) \(rendered)"
    }

    private func timestamp() -> String {
        var now = time(nil)
        var parts = tm()
        gmtime_r(&now, &parts)
        var buffer = [Int8](repeating: 0, count: 32)
        let count = strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%SZ", &parts)
        return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

extension IPCMessage.LogLevel {
    init(_ level: Logger.Level) {
        switch level {
        case .trace: self = .trace
        case .debug: self = .debug
        case .info, .notice: self = .info
        case .warning: self = .warn
        case .error: self = .error
        case .critical: self = .fatal
        }
    }
}
