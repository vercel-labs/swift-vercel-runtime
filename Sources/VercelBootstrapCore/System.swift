#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Small libc wrappers, kept free of Foundation so the bootstrap binary stays small.
//
// Throughout the bootstrap, avoid string APIs such as `String.contains(_: String)`: with NIOPosix
// imported they resolve to Foundation's NSString API, which links all of Foundation and its ICU
// data (~40 MB) into the static binary. `scripts/test-linux.sh` checks for this.

/// The whole file, or `nil` if it cannot be read.
package func readFile(_ path: String) -> [UInt8]? {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { _ = close(fd) }
    var contents: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 16384)
    while true {
        let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            contents.append(contentsOf: chunk[0..<count])
        } else if count == 0 {
            return contents
        } else if errno != EINTR {
            return nil
        }
    }
}

/// The target of a symbolic link, or `nil`.
package func readLink(_ path: String) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let count = readlink(path, &buffer, buffer.count - 1)
    guard count >= 0 else { return nil }
    return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Names in a directory, excluding `.` and `..`, or `nil` if it cannot be listed.
package func listDirectory(_ path: String) -> [String]? {
    guard let directory = opendir(path) else { return nil }
    defer { closedir(directory) }
    var names: [String] = []
    while let entry = readdir(directory) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        if name != ".", name != ".." {
            names.append(name)
        }
    }
    return names
}

/// The directory containing this executable: the function directory on Vercel.
package func executableDirectory() -> String {
    #if os(Linux)
    if let path = readLink("/proc/self/exe") {
        return directoryName(path)
    }
    #endif
    let argument0 = CommandLine.arguments.first ?? ""
    if argument0.hasPrefix("/") {
        return directoryName(argument0)
    }
    var buffer = [CChar](repeating: 0, count: 4096)
    let cwd = getcwd(&buffer, buffer.count).map { String(cString: $0) } ?? "."
    return argument0.utf8.contains(UInt8(ascii: "/")) ? directoryName(cwd + "/" + argument0) : cwd
}

package func directoryName(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "." }
    return slash == path.startIndex ? "/" : String(path[..<slash])
}

/// The process environment as key/value pairs, in order.
package func currentEnvironment() -> [(String, String)] {
    #if os(Linux)
    // The bootstrap never changes its environment, so the initial one is the current one.
    let entries = (readFile("/proc/self/environ") ?? []).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    #else
    var entries: [String] = []
    var pointer = environ
    while let entry = pointer.pointee {
        entries.append(String(cString: entry))
        pointer += 1
    }
    #endif
    return entries.compactMap { entry in
        guard let equals = entry.firstIndex(of: "=") else { return nil }
        return (String(entry[..<equals]), String(entry[entry.index(after: equals)...]))
    }
}

/// A free TCP port on 127.0.0.1, found by binding port 0. Another process could take it before it
/// is used, which is not a concern inside a function instance.
package func reserveFreePort() throws -> Int {
    #if canImport(Glibc)
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { throw BootstrapError("socket() failed: errno \(errno)") }
    defer { _ = close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw BootstrapError("bind() failed: errno \(errno)") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length)
        }
    }
    guard named == 0 else { throw BootstrapError("getsockname() failed: errno \(errno)") }
    return Int(UInt16(bigEndian: address.sin_port))
}

/// Whether something accepts TCP connections on `127.0.0.1:port`. Used to detect readiness where
/// `/proc` is not available (macOS).
package func acceptsConnections(port: Int) -> Bool {
    #if canImport(Glibc)
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { return false }
    defer { _ = close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}
