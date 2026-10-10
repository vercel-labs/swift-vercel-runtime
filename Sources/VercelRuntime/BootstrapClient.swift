#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import NIOCore
import Synchronization

/// The app's connection to `VercelBootstrap`, which runs it on Vercel.
///
/// Only apps that use ``Vercel/withRequest(_:_:)``, ``Vercel/waitUntil(for:_:)`` or
/// ``VercelLogHandler`` connect. Locally, or when the app runs outside the bootstrap, there is no
/// client and those APIs fall back to plain behavior.
final class BootstrapClient: Sendable {
    /// The process-wide client, connected on first access. `nil` outside the bootstrap.
    static let shared: BootstrapClient? = {
        guard let path = environmentValue(BootstrapProtocol.socketVariable), !path.isEmpty else { return nil }
        do {
            return try BootstrapClient(path: path)
        } catch {
            writeToStandardError("[vercel] failed to connect to the Vercel bootstrap: \(error)")
            return nil
        }
    }()

    private let connection = Mutex<IPCConnection?>(nil)
    private let scopes = Mutex<[String: RequestScope]>([:])

    /// Connects and waits for the bootstrap's `ready`, so the bootstrap knows about this app
    /// before any request it is handling can finish.
    init(path: String) throws {
        let descriptor = try unixConnect(path: path)
        do {
            let frame = try readFrameBlocking(descriptor)
            guard BootstrapMessage(frame: frame) == .ready else {
                throw IPCConnection.Error.handshake("unexpected first message: \(String(decoding: frame, as: UTF8.self))")
            }
        } catch {
            _ = closeDescriptor(descriptor)
            throw error
        }
        // Held while connecting, so a frame handled right away waits for `connection` to be set.
        connection.withLock { connection in
            connection = IPCConnection(descriptor: descriptor) { [self] frame in
                self.receive(frame)
            }
        }
    }

    /// The scope for a request token, created on first use.
    func scope(for token: String) -> RequestScope {
        scopes.withLock { scopes in
            if let scope = scopes[token] { return scope }
            let scope = RequestScope(token: token, client: self)
            scopes[token] = scope
            return scope
        }
    }

    func log(_ message: String, level: IPCMessage.LogLevel, token: String) {
        send(.log(token: token, message: message, level: level))
    }

    /// Called by a scope once its response finished and its `waitUntil` work is done.
    func released(_ scope: RequestScope) {
        scopes.withLock { scopes in
            if scopes[scope.token] === scope {
                scopes[scope.token] = nil
            }
        }
        send(.release(token: scope.token))
    }

    var activeScopeCount: Int {
        scopes.withLock { $0.count }
    }

    func flush() async {
        await connection.withLock { $0 }?.flush()
    }

    func close() async {
        await connection.withLock { $0 }?.close()
    }

    private func send(_ message: AppMessage) {
        connection.withLock { $0 }?.send(json: message.json, droppable: message.isDroppable)
    }

    private func receive(_ frame: ByteBuffer) {
        guard let message = BootstrapMessage(frame: frame.readableBytesView) else { return }
        switch message {
        case .ready:
            break
        case .responseFinished(let token):
            if let scope = scopes.withLock({ $0[token] }) {
                scope.responseFinished()
            } else {
                // Nothing in this process is tracking the request.
                send(.release(token: token))
            }
        case .approachingTimeout(let token):
            scopes.withLock { $0[token] }?.cancelBackgroundWork()
        }
    }
}

private func closeDescriptor(_ fd: CInt) -> CInt {
    close(fd)
}
