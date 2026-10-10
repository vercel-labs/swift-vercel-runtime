/// Finds the TCP port the app listens on, so apps work whether or not they read `PORT`.
///
/// On Linux it reads which listening sockets the app process owns from `/proc`: the socket inodes
/// in `/proc/<pid>/fd` matched against `LISTEN` entries in `/proc/net/tcp` and `/proc/net/tcp6`.
/// Without `/proc` (macOS), the bootstrap falls back to probing `PORT` and ``commonPorts``.
package enum PortDiscovery {
    /// Ports HTTP servers listen on by default, in order of preference.
    package static let commonPorts = [8080, 3000, 8000]

    /// A listening socket, with the address to connect to it on.
    package struct Listener: Sendable, Hashable, CustomStringConvertible {
        /// IP literal to connect to: the bound address, or loopback for a wildcard bind.
        package var host: String
        package var port: Int

        package init(host: String, port: Int) {
            self.host = host
            self.port = port
        }

        package var description: String {
            host.utf8.contains(UInt8(ascii: ":")) ? "[\(host)]:\(port)" : "\(host):\(port)"
        }
    }

    /// The listening TCP sockets owned by `pid`, or `nil` when `/proc` is not available.
    package static func listeners(pid: Int32) -> [Listener]? {
        guard let inodes = socketInodes(pid: pid) else { return nil }
        guard !inodes.isEmpty else { return [] }
        var result: [Listener] = []
        if let table = readFile("/proc/net/tcp") {
            result += parseTCPTable(String(decoding: table, as: UTF8.self), ipv6: false, inodes: inodes)
        }
        if let table = readFile("/proc/net/tcp6") {
            result += parseTCPTable(String(decoding: table, as: UTF8.self), ipv6: true, inodes: inodes)
        }
        return result
    }

    /// Inodes of the sockets in `/proc/<pid>/fd`, or `nil` when it cannot be read.
    static func socketInodes(pid: Int32) -> Set<UInt64>? {
        let directory = "/proc/\(pid)/fd"
        guard let entries = listDirectory(directory) else { return nil }
        var inodes = Set<UInt64>()
        for entry in entries {
            // "socket:[12345]"
            guard let target = readLink("\(directory)/\(entry)"), target.hasPrefix("socket:["), target.hasSuffix("]") else {
                continue
            }
            if let inode = UInt64(target.dropFirst(8).dropLast()) {
                inodes.insert(inode)
            }
        }
        return inodes
    }

    /// Parses `/proc/net/tcp` or `/proc/net/tcp6`, keeping `LISTEN` sockets whose inode is in
    /// `inodes`.
    package static func parseTCPTable(_ table: String, ipv6: Bool, inodes: Set<UInt64>) -> [Listener] {
        var result: [Listener] = []
        for line in table.split(separator: "\n").dropFirst() {
            // sl local_address rem_address st tx_queue:rx_queue tr:tm->when retrnsmt uid timeout inode
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > 9, fields[3] == "0A", let inode = UInt64(fields[9]), inodes.contains(inode) else {
                continue
            }
            let local = fields[1].split(separator: ":")
            guard local.count == 2, let port = Int(local[1], radix: 16),
                let host = ipv6 ? ipv6Host(local[0]) : ipv4Host(local[0])
            else { continue }
            result.append(Listener(host: host, port: port))
        }
        return result
    }

    /// Picks the app's HTTP port: `preferredPort` (the `PORT` the app was given) if it listens
    /// there, otherwise its only port, otherwise a common HTTP port, otherwise the lowest.
    package static func choose(_ listeners: [Listener], preferredPort: Int) -> Listener? {
        // One entry per port; IPv4 first since the wildcard IPv6 bind usually also accepts IPv4.
        var byPort: [Int: Listener] = [:]
        for listener in listeners where byPort[listener.port] == nil || !listener.host.utf8.contains(UInt8(ascii: ":")) {
            byPort[listener.port] = listener
        }
        if let preferred = byPort[preferredPort] { return preferred }
        if byPort.count == 1 { return byPort.values.first }
        for port in commonPorts {
            if let listener = byPort[port] { return listener }
        }
        return byPort.keys.min().flatMap { byPort[$0] }
    }

    /// `0100007F` (host byte order on little-endian machines) → `127.0.0.1`. Wildcard → loopback.
    static func ipv4Host(_ hex: Substring) -> String? {
        guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        let bytes = littleEndianWordBytes(value)
        if bytes == [0, 0, 0, 0] { return "127.0.0.1" }
        return bytes.map(String.init).joined(separator: ".")
    }

    /// 32 hex digits as four little-endian words → an IPv6 literal. Wildcard → `::1`.
    static func ipv6Host(_ hex: Substring) -> String? {
        guard hex.count == 32 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        for _ in 0..<4 {
            let next = hex.index(index, offsetBy: 8)
            guard let word = UInt32(hex[index..<next], radix: 16) else { return nil }
            bytes += littleEndianWordBytes(word)
            index = next
        }
        if bytes.allSatisfy({ $0 == 0 }) { return "::1" }
        return stride(from: 0, to: 16, by: 2)
            .map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }
            .joined(separator: ":")
    }

    /// The kernel prints each 32-bit word of the address in host order; Vercel runs on
    /// little-endian machines (arm64 and x86_64), so the first network byte is the lowest.
    private static func littleEndianWordBytes(_ word: UInt32) -> [UInt8] {
        [UInt8(word & 0xFF), UInt8(word >> 8 & 0xFF), UInt8(word >> 16 & 0xFF), UInt8(word >> 24)]
    }
}
