#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import NIOCore
import NIOPosix

/// A connection carrying NUL-terminated JSON messages over a Unix socket.
///
/// Used twice: by the bootstrap to talk to the Vercel functions runtime (`VERCEL_IPC_PATH`), and
/// by an app to talk to the bootstrap (`VERCEL_BOOTSTRAP_SOCKET`).
///
/// All socket I/O is non-blocking and runs on a SwiftNIO event loop:
/// - ``send(json:droppable:)`` appends the message to an in-memory outbox and returns. It never
///   waits for the socket, so it is safe from synchronous code such as swift-log handlers and
///   never stalls Swift's cooperative thread pool.
/// - A single writer task drains the outbox, writing everything queued with one flush and waiting
///   for the write to complete before taking the next batch. Frames keep their order.
/// - Incoming frames are delivered to `onFrame` in order.
package final class IPCConnection: Sendable {
    package enum Error: Swift.Error, Equatable {
        case pathTooLong(String)
        case socket(errno: Int32)
        case connect(path: String, errno: Int32)
        case handshake(String)
    }

    let outbox: IPCOutbox
    private let task: Task<Void, Never>

    /// Connects to the Unix domain socket at `path`.
    ///
    /// The connect itself is synchronous, so a missing or refused socket throws immediately.
    package convenience init(
        path: String,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        onFrame: @escaping @Sendable (ByteBuffer) -> Void = { _ in }
    ) throws {
        try self.init(descriptor: unixConnect(path: path), eventLoopGroup: eventLoopGroup, onFrame: onFrame)
    }

    /// Takes ownership of an already connected socket.
    package init(
        descriptor: CInt,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        onFrame: @escaping @Sendable (ByteBuffer) -> Void = { _ in }
    ) {
        let outbox = IPCOutbox()
        self.outbox = outbox
        // Detached: the connection lives for the whole process and must not inherit the caller's
        // task-locals or priority.
        self.task = Task.detached {
            await Self.run(descriptor: descriptor, eventLoopGroup: eventLoopGroup, outbox: outbox, onFrame: onFrame)
        }
    }

    /// Queues a message. Returns immediately; `false` means it was dropped, either because it is
    /// `droppable` and the other side is not keeping up, or because the connection is closed.
    @discardableResult
    package func send(json: String, droppable: Bool = false) -> Bool {
        outbox.enqueue(json, isLog: droppable)
    }

    /// Waits until every message sent before this call has been written to the socket.
    package func flush() async {
        await outbox.flush()
    }

    /// Writes any queued messages, then closes the socket.
    package func close() async {
        outbox.finish()
        await task.value
    }

    /// Droppable messages dropped because the other side was not reading fast enough.
    package var droppedLogCount: Int {
        outbox.totalDroppedLogs
    }

    deinit {
        outbox.finish()
    }

    private static func run(
        descriptor: CInt,
        eventLoopGroup: any EventLoopGroup,
        outbox: IPCOutbox,
        onFrame: @escaping @Sendable (ByteBuffer) -> Void
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
                            onFrame(frame)
                        }
                        // The other side closed its end of the socket.
                        outbox.terminate()
                    }

                    while let batch = await outbox.nextBatch() {
                        if batch.droppedLogs > 0 {
                            writeToStandardError("[vercel] dropped \(batch.droppedLogs) log messages: the receiver was not reading fast enough")
                        }
                        try await channel.writeAndFlush(batch.bytes).get()
                        outbox.batchWritten()
                    }
                    group.cancelAll()
                }
            }
        } catch is CancellationError {
            // Closed by `close()`: the reader stops once the writer has drained.
        } catch {
            writeToStandardError("[vercel] IPC connection closed: \(error)")
        }
        outbox.terminate()
    }
}

/// Splits a byte stream into NUL-terminated frames.
package struct NULDelimitedFrameDecoder: ByteToMessageDecoder {
    package typealias InboundOut = ByteBuffer

    /// Control messages are tiny and logs are capped well below this; refuse to buffer unbounded
    /// garbage.
    static let maxFrameLength = 1 << 20

    package init() {}

    package mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
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

    package mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}

// MARK: - System calls
// Kept as free functions so names like `connect` and `close` refer to libc.

/// Connects a Unix stream socket, blocking. Fine here: it is a local socket, it completes
/// immediately, and it runs once per process. Everything after it is non-blocking.
///
/// The descriptor is close-on-exec so child processes never inherit it.
package func unixConnect(path: String) throws -> CInt {
    #if canImport(Glibc)
    let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    let streamType = SOCK_STREAM
    #endif

    let fd = socket(AF_UNIX, streamType, 0)
    guard fd >= 0 else { throw IPCConnection.Error.socket(errno: errno) }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

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

/// Reads one NUL-terminated frame from a blocking socket, giving up after `timeoutSeconds`.
///
/// Reads a byte at a time so nothing past the frame is consumed: the descriptor is handed to
/// SwiftNIO right after.
package func readFrameBlocking(_ fd: CInt, timeoutSeconds: Int = 5) throws -> [UInt8] {
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    defer {
        var none = timeval(tv_sec: 0, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
    }
    var frame: [UInt8] = []
    var byte: UInt8 = 0
    while frame.count < 4096 {
        let count = read(fd, &byte, 1)
        if count == 1 {
            if byte == 0 { return frame }
            frame.append(byte)
        } else if count < 0 && errno == EINTR {
            continue
        } else {
            throw IPCConnection.Error.handshake(count == 0 ? "socket closed" : "read failed (errno \(errno))")
        }
    }
    throw IPCConnection.Error.handshake("frame too long")
}

package func environmentValue(_ name: String) -> String? {
    guard let value = getenv(name) else { return nil }
    return String(cString: value)
}

/// Diagnostics only: a rare, small, synchronous write to stderr.
package func writeToStandardError(_ message: String) {
    writeLine(message, to: 2)
}

/// Writes a line with a single write(2), so concurrent lines never interleave.
package func writeLine(_ message: String, to descriptor: CInt) {
    var line = message
    if !line.hasSuffix("\n") { line += "\n" }
    let bytes = Array(line.utf8)
    bytes.withUnsafeBytes { buffer in
        _ = write(descriptor, buffer.baseAddress, buffer.count)
    }
}
