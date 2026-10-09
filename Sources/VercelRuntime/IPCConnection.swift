#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import NIOCore
import NIOPosix

/// The connection to the Vercel functions runtime over the `VERCEL_IPC_PATH` Unix socket.
///
/// All socket I/O is non-blocking and runs on a SwiftNIO event loop:
/// - ``send(_:)`` encodes the message on the caller's thread and appends it to an in-memory
///   outbox. It never waits for the socket, so it is safe from synchronous code such as swift-log
///   handlers and never stalls Swift's cooperative thread pool.
/// - A single writer task drains the outbox, writing everything queued with one flush and waiting
///   for the write to complete before taking the next batch. Frames keep their order.
/// - Messages from the runtime (like `approaching-timeout`) are read as an async sequence and
///   delivered to the `onMessage` handler.
public final class IPCConnection: Sendable {
    public enum Error: Swift.Error, Equatable {
        case pathTooLong(String)
        case socket(errno: Int32)
        case connect(path: String, errno: Int32)
    }

    let outbox: IPCOutbox
    private let task: Task<Void, Never>

    /// Connects to the Unix domain socket at `path`.
    ///
    /// The connect itself is synchronous, so a missing or refused socket throws immediately. The
    /// connected socket is then handed to SwiftNIO, which owns it from there.
    public init(
        path: String,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        onMessage: @escaping @Sendable (RuntimeMessage) -> Void = { _ in }
    ) throws {
        let descriptor = try unixConnect(path: path)
        let outbox = IPCOutbox()
        self.outbox = outbox
        // Detached: the connection lives for the whole process and must not inherit the caller's
        // task-locals or priority.
        self.task = Task.detached {
            await Self.run(descriptor: descriptor, eventLoopGroup: eventLoopGroup, outbox: outbox, onMessage: onMessage)
        }
    }

    /// Queues a message. Returns immediately; `false` means it was dropped because the runtime is
    /// not keeping up (only `log` messages are ever dropped) or the connection is closed.
    @discardableResult
    public func send(_ message: IPCMessage) -> Bool {
        let isLog = if case .log = message { true } else { false }
        return outbox.enqueue(message.json, isLog: isLog)
    }

    /// Waits until every message sent before this call has been written to the socket.
    public func flush() async {
        await outbox.flush()
    }

    /// Writes any queued messages, then closes the socket.
    public func close() async {
        outbox.finish()
        await task.value
    }

    /// `log` messages dropped because the runtime was not reading fast enough.
    public var droppedLogCount: Int {
        outbox.totalDroppedLogs
    }

    deinit {
        outbox.finish()
    }

    private static func run(
        descriptor: CInt,
        eventLoopGroup: any EventLoopGroup,
        outbox: IPCOutbox,
        onMessage: @escaping @Sendable (RuntimeMessage) -> Void
    ) async {
        do {
            let asyncChannel = try await ClientBootstrap(group: eventLoopGroup).withConnectedSocket(descriptor) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(NULDelimitedFrameDecoder()))
                    // Inbound only: writes go through the channel directly so their completion can
                    // be awaited (the async outbound writer does not report it).
                    return try NIOAsyncChannel<ByteBuffer, Never>(wrappingChannelSynchronously: channel)
                }
            }
            let channel = asyncChannel.channel

            try await asyncChannel.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { group in
                    group.addTask {
                        for try await frame in inbound {
                            if let message = RuntimeMessage(frame: frame.readableBytesView) {
                                onMessage(message)
                            }
                        }
                        // The runtime closed its end of the socket.
                        outbox.terminate()
                    }

                    while let batch = await outbox.nextBatch() {
                        if batch.droppedLogs > 0 {
                            writeToStandardError("[vercel] dropped \(batch.droppedLogs) log messages: the runtime was not reading fast enough")
                        }
                        try await channel.writeAndFlush(batch.bytes).get()
                        outbox.batchWritten()
                    }
                    group.cancelAll()
                }
            }
        } catch {
            writeToStandardError("[vercel] IPC connection closed: \(error)")
        }
        outbox.terminate()
    }
}

/// Splits the runtime's byte stream into NUL-terminated frames.
struct NULDelimitedFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    /// Messages from the runtime are tiny; refuse to buffer unbounded garbage.
    static let maxFrameLength = 1 << 20

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let view = buffer.readableBytesView
        guard let terminator = view.firstIndex(of: 0) else {
            guard buffer.readableBytes <= Self.maxFrameLength else {
                throw ByteToMessageDecoderError.PayloadTooLargeError()
            }
            return .needMoreData
        }
        let frame = buffer.readSlice(length: view.distance(from: view.startIndex, to: terminator))!
        buffer.moveReaderIndex(forwardBy: 1)
        context.fireChannelRead(Self.wrapInboundOut(frame))
        return .continue
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}

// MARK: - System calls
// Kept as free functions so names like `connect` and `close` refer to libc.

/// A blocking connect is fine here: it is a local Unix socket, it completes immediately, and it
/// runs once at startup. Everything after it is non-blocking.
private func unixConnect(path: String) throws -> CInt {
    #if canImport(Glibc)
    let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    let streamType = SOCK_STREAM
    #endif

    let fd = socket(AF_UNIX, streamType, 0)
    guard fd >= 0 else { throw IPCConnection.Error.socket(errno: errno) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    #if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif

    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        _ = close(fd)
        throw IPCConnection.Error.pathTooLong(path)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: pathBytes)
    }

    while true {
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return fd }
        if errno == EINTR { continue }
        let error = errno
        _ = close(fd)
        throw IPCConnection.Error.connect(path: path, errno: error)
    }
}

func environmentValue(_ name: String) -> String? {
    guard let value = getenv(name) else { return nil }
    return String(cString: value)
}

/// Diagnostics only: a rare, small, synchronous write to stderr.
func writeToStandardError(_ message: String) {
    var line = message
    if !line.hasSuffix("\n") { line += "\n" }
    let bytes = Array(line.utf8)
    bytes.withUnsafeBytes { buffer in
        _ = write(2, buffer.baseAddress, buffer.count)
    }
}
