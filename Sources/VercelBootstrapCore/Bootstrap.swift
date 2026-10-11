#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import NIOCore
import NIOPosix
import Synchronization
import VercelProtocol

/// The function entrypoint on Vercel.
///
/// Runs the app (any Swift HTTP server) as a child process and implements the functions runtime
/// contract for it:
///
/// 1. connects to `VERCEL_IPC_PATH`,
/// 2. starts the app with `PORT` set, and finds the port it actually listens on,
/// 3. listens on `127.0.0.1` and reports that port with `server-started`,
/// 4. proxies every request to the app: answers `/_vercel/ping`, strips the runtime's internal
///    headers, enforces `CRON_SECRET` on cron paths, streams bodies, tunnels WebSockets,
/// 5. sends `end` once each response is done (and the app's `waitUntil` work, if any),
/// 6. forwards `SIGTERM` to the app, and reports the app exiting as an unrecoverable error.
package enum Bootstrap {
    /// How long the app may take to start listening.
    static let startupTimeout: Duration = .seconds(60)

    private enum Event: Sendable {
        case listening(PortDiscovery.Listener)
        case startupTimedOut
        case appExited(ExitStatus)
        case signal(Int32)
    }

    /// Runs until the app exits or the bootstrap is asked to stop. Returns the exit code.
    package static func run() async -> Int32 {
        let startedAt = ContinuousClock.now
        let runtime = RuntimeLink()
        let tracker = RequestTracker { message in runtime.send(message) }

        if let ipcPath = environmentValue("VERCEL_IPC_PATH"), !ipcPath.isEmpty {
            do {
                try runtime.connect(path: ipcPath) { message in
                    if case .approachingTimeout(let context) = message {
                        tracker.approachingTimeout(context)
                    }
                }
            } catch {
                writeToStandardError("[vercel] cannot connect to the functions runtime: \(error)")
                return 1
            }
        }

        func fail(_ message: String, exitCode: Int32 = 1) async -> Int32 {
            await runtime.unrecoverableError(exitCode: exitCode, message: "[vercel] \(message)")
            return exitCode
        }

        let (events, emit) = AsyncStream<Event>.makeStream()

        // 1. Start the app.
        let directory = executableDirectory()
        let configuration: BootstrapConfiguration
        let app: ChildProcess
        let appPort: Int
        let socketPath = "/tmp/vercel-bootstrap-\(getpid()).sock"
        let group = MultiThreadedEventLoopGroup.singleton
        let appSocket: any Channel
        let signals: any Channel
        do {
            configuration = try BootstrapConfiguration.load(directory: directory)
            // Before the app starts, so its exit (SIGCHLD) cannot be missed.
            signals = try await SignalPipe.start(signals: [SIGTERM, SIGINT, SIGCHLD], group: group) { emit.yield(.signal($0)) }
            appSocket = try await AppSocket.bind(path: socketPath, tracker: tracker, group: group)
            appPort = try reserveFreePort()
            var environment = currentEnvironment().filter {
                !["VERCEL_IPC_PATH", "PORT", BootstrapProtocol.socketVariable].contains($0.0)
            }
            environment.append(("PORT", String(appPort)))
            environment.append((BootstrapProtocol.socketVariable, socketPath))
            app = try ChildProcess.spawn(path: directory + "/" + configuration.executable, environment: environment)
        } catch {
            return await fail("\(error)")
        }
        defer {
            appSocket.close(promise: nil)
            signals.close(promise: nil)
            unlink(socketPath)
        }
        let discovery = Task {
            if let listener = await waitForListener(pid: app.pid, preferredPort: appPort) {
                emit.yield(.listening(listener))
            } else if !Task.isCancelled {
                emit.yield(.startupTimedOut)
            }
        }
        defer { discovery.cancel() }

        // 2. Wait until it listens, then start proxying.
        var proxy: (any Channel)?
        var shuttingDown = false
        for await event in events {
            switch event {
            case .listening(let listener):
                guard proxy == nil, !shuttingDown else { continue }
                if listener.port != appPort {
                    writeToStandardError("[vercel] the app listens on \(listener) instead of PORT=\(appPort); proxying to it")
                }
                do {
                    let upstream = try SocketAddress(ipAddress: listener.host, port: listener.port)
                    let channel = try await ProxyServer.bind(
                        configuration: ProxyConfiguration(
                            upstream: upstream,
                            tracker: tracker,
                            configuration: configuration,
                            cronSecret: environmentValue("CRON_SECRET")
                        ),
                        group: group
                    )
                    proxy = channel
                    guard let port = channel.localAddress?.port else {
                        throw BootstrapError("the proxy has no local port")
                    }
                    let elapsed = ContinuousClock.now - startedAt
                    let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
                    runtime.send(.serverStarted(initDuration: UInt64(max(0, milliseconds)), httpPort: UInt16(port)))
                    if !runtime.isConnected {
                        writeLine("VercelBootstrap: http://127.0.0.1:\(port) -> app at \(listener)", to: 1)
                    }
                } catch {
                    app.signal(SIGKILL)
                    return await fail("cannot start the proxy: \(error)")
                }

            case .startupTimedOut:
                guard proxy == nil, !shuttingDown else { continue }
                app.signal(SIGKILL)
                return await fail(
                    "the app did not start listening on a TCP port within \(startupTimeout). It should listen on 127.0.0.1 (or 0.0.0.0), ideally on PORT=\(appPort)."
                )

            case .signal(SIGCHLD):
                if let status = app.reap() {
                    emit.yield(.appExited(status))
                }

            case .signal(let signal):
                if shuttingDown {
                    // A second signal: stop waiting.
                    app.signal(SIGKILL)
                    continue
                }
                shuttingDown = true
                discovery.cancel()
                app.signal(signal)

            case .appExited(let status):
                proxy?.close(promise: nil)
                if shuttingDown {
                    await runtime.shutdown()
                    switch status {
                    case .exited(let code): return code
                    case .signaled(let signal) where signal == SIGTERM || signal == SIGINT: return 0
                    case .signaled(let signal): return 128 + signal
                    }
                }
                let exitCode: Int32 =
                    switch status {
                    case .exited(let code): code == 0 ? 1 : code
                    case .signaled(let signal): 128 + signal
                    }
                let when = proxy == nil ? "before it started listening" : "unexpectedly"
                return await fail("the app exited \(when) (\(status))", exitCode: exitCode)
            }
        }
        return 1
    }

    /// Polls until the app listens on a TCP port. Returns `nil` on timeout or cancellation.
    ///
    /// Reads the app's listening sockets from `/proc` where possible. Where `/proc` gives no
    /// answer (not mounted, or restricted by the sandbox), probes `PORT` and then common HTTP ports
    /// with a TCP connect.
    static func waitForListener(pid: Int32, preferredPort: Int) async -> PortDiscovery.Listener? {
        let probedPorts = [preferredPort] + PortDiscovery.commonPorts.filter { $0 != preferredPort }
        let started = ContinuousClock.now
        while ContinuousClock.now - started < startupTimeout {
            if let listener = PortDiscovery.listeners(pid: pid).flatMap({ PortDiscovery.choose($0, preferredPort: preferredPort) }) {
                return listener
            }
            if let port = probedPorts.first(where: acceptsConnections(port:)) {
                return PortDiscovery.Listener(host: "127.0.0.1", port: port)
            }
            // Poll fast at first: this is on the cold start path.
            let interval: Duration = ContinuousClock.now - started < .seconds(1) ? .milliseconds(2) : .milliseconds(20)
            do {
                try await Task.sleep(for: interval)
            } catch {
                return nil
            }
        }
        return nil
    }
}

/// The connection to the Vercel functions runtime, or nothing when running locally.
final class RuntimeLink: Sendable {
    private let connection = Mutex<IPCConnection?>(nil)

    var isConnected: Bool {
        connection.withLock { $0 != nil }
    }

    func connect(path: String, onMessage: @escaping @Sendable (RuntimeMessage) -> Void) throws {
        let connection = try IPCConnection(path: path) { frame in
            if let message = RuntimeMessage(frame: frame.readableBytesView) {
                onMessage(message)
            }
        }
        self.connection.withLock { $0 = connection }
    }

    func send(_ message: IPCMessage) {
        connection.withLock { $0 }?.send(json: message.json, droppable: message.isDroppable)
    }

    /// Reports a fatal error and waits until it has been written.
    func unrecoverableError(exitCode: Int32, message: String) async {
        writeToStandardError(message)
        send(.unrecoverableError(exitCode: exitCode, message: message))
        await connection.withLock { $0 }?.flush()
    }

    func shutdown() async {
        await connection.withLock { $0 }?.close()
    }
}

/// Delivers signals as callbacks: a `signal(2)` handler writes the signal number to a pipe that
/// SwiftNIO reads on an event loop.
///
/// Dispatch signal sources would be simpler, but linking Dispatch's I/O code pulls all of
/// Foundation (and ~40 MB of ICU data) into the static binary.
enum SignalPipe {
    static func start(
        signals: [Int32],
        group: any EventLoopGroup,
        handler: @escaping @Sendable (Int32) -> Void
    ) async throws -> any Channel {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw BootstrapError("pipe() failed: errno \(errno)")
        }
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        // The handler must never block.
        _ = fcntl(descriptors[1], F_SETFL, fcntl(descriptors[1], F_GETFL) | O_NONBLOCK)
        signalPipeWriteDescriptor = descriptors[1]

        let channel = try await NIOPipeBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(SignalPipeHandler(handler: handler))
                }
            }
            .takingOwnershipOfDescriptor(input: descriptors[0])
            .get()
        for number in signals {
            _ = signal(number, signalPipeHandler)
        }
        return channel
    }
}

nonisolated(unsafe) private var signalPipeWriteDescriptor: Int32 = -1

/// Only async-signal-safe work: one `write(2)`, preserving `errno`.
private let signalPipeHandler: @convention(c) (Int32) -> Void = { number in
    let savedErrno = errno
    var byte = UInt8(truncatingIfNeeded: number)
    _ = write(signalPipeWriteDescriptor, &byte, 1)
    errno = savedErrno
}

private final class SignalPipeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    let handler: @Sendable (Int32) -> Void

    init(handler: @escaping @Sendable (Int32) -> Void) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        for byte in unwrapInboundIn(data).readableBytesView {
            handler(Int32(byte))
        }
    }
}
