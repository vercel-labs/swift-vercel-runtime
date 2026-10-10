import NIOCore
import NIOPosix
import VercelRuntime

/// The Unix socket apps connect to (via `VercelRuntime`) for per-request logs and `waitUntil`.
package enum AppSocket {
    /// Listens on `path`, replacing any stale socket file.
    package static func bind(path: String, tracker: RequestTracker, group: any EventLoopGroup) async throws -> any Channel {
        try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(NULDelimitedFrameDecoder()))
                    try channel.pipeline.syncOperations.addHandler(AppConnectionHandler(tracker: tracker))
                }
            }
            .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true)
            .get()
    }
}

/// Sends messages to the app. Safe from any thread: channel writes hop to its event loop.
final class AppConnection: AppPeer {
    let channel: any Channel

    init(channel: any Channel) {
        self.channel = channel
    }

    func send(_ message: BootstrapMessage) {
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString(message.json)
        buffer.writeInteger(UInt8(0))
        channel.writeAndFlush(buffer, promise: nil)
    }
}

final class AppConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    let tracker: RequestTracker
    private var connection: AppConnection?

    init(tracker: RequestTracker) {
        self.tracker = tracker
    }

    func channelActive(context: ChannelHandlerContext) {
        let connection = AppConnection(channel: context.channel)
        guard tracker.appConnected(connection) else {
            writeToStandardError("[vercel] rejected a second app connection to the bootstrap socket")
            context.close(promise: nil)
            return
        }
        self.connection = connection
        // Registered first, so `ready` means the bootstrap will wait for this app.
        connection.send(.ready)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch AppMessage(frame: frame.readableBytesView) {
        case .log(let token, let message, let level):
            tracker.log(token: token, message: message, level: level)
        case .release(let token):
            tracker.released(token: token)
        case nil:
            writeToStandardError("[vercel] ignored an invalid message from the app")
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let connection {
            tracker.appDisconnected(connection)
            self.connection = nil
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
