#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Dispatch
import Testing

/// Plays the Vercel functions runtime side of the IPC socket in tests.
///
/// Reads are blocking syscalls, so they run on a dispatch thread and never occupy Swift's
/// cooperative pool (which the code under test needs). Used by one test at a time.
final class TestSocket: @unchecked Sendable {
    struct Timeout: Error {}

    let path: String
    private let listener: Int32
    private var peer: Int32 = -1
    private var buffer: [UInt8] = []

    init() throws {
        path = "/tmp/vswift-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        #if canImport(Glibc)
        listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        try #require(listener >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(listen(listener, 1) == 0)
    }

    /// Accepts the runtime's connection. Reads time out after `timeout` seconds.
    func accept(timeout: Int = 5) throws {
        peer = acceptConnection(listener)
        try #require(peer >= 0)
        setReadTimeout(milliseconds: timeout * 1000)
    }

    func setReadTimeout(milliseconds: Int) {
        var limit = timeval(tv_sec: milliseconds / 1000, tv_usec: .init((milliseconds % 1000) * 1000))
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The next NUL-terminated frame, as a string.
    func nextFrame() async throws -> String {
        try await onReaderThread { try self.readFrame() }
    }

    /// The next `count` frames.
    func frames(_ count: Int) async throws -> [String] {
        try await onReaderThread { try (0..<count).map { _ in try self.readFrame() } }
    }

    /// Frames until `predicate` matches one (included).
    func frames(until predicate: @escaping @Sendable (String) -> Bool) async throws -> [String] {
        try await onReaderThread {
            var frames: [String] = []
            while true {
                let frame = try self.readFrame()
                frames.append(frame)
                if predicate(frame) { return frames }
            }
        }
    }

    /// Whether the other side closed the connection (and nothing else is buffered).
    func isClosed() async throws -> Bool {
        try await onReaderThread {
            guard self.buffer.isEmpty else { return false }
            var byte: UInt8 = 0
            let count = read(self.peer, &byte, 1)
            if count == 0 { return true }
            if count < 0 { throw Timeout() }
            self.buffer.append(byte)
            return false
        }
    }

    /// Closes the connection, like a peer that exits.
    func closePeer() {
        if peer >= 0 {
            close(peer)
            peer = -1
        }
    }

    /// Sends raw bytes to the function process.
    func sendRaw(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { _ = write(peer, $0.baseAddress, $0.count) }
    }

    /// Sends a frame to the function process, like the runtime's `approaching-timeout`.
    func send(_ json: String) {
        sendRaw(Array(json.utf8) + [0])
    }

    private func readFrame() throws -> String {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !buffer.contains(0) {
            let count = chunk.withUnsafeMutableBytes { read(peer, $0.baseAddress, $0.count) }
            guard count > 0 else { throw Timeout() }
            buffer.append(contentsOf: chunk[0..<count])
        }
        let end = buffer.firstIndex(of: 0)!
        let frame = String(decoding: buffer[..<end], as: UTF8.self)
        buffer.removeSubrange(...end)
        return frame
    }

    private func onReaderThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    deinit {
        if peer >= 0 { close(peer) }
        close(listener)
        unlink(path)
    }
}

private func acceptConnection(_ listener: Int32) -> Int32 {
    accept(listener, nil, nil)
}
