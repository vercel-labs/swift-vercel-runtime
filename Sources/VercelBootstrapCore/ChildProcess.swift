#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// How a process ended.
package enum ExitStatus: Sendable, Equatable, CustomStringConvertible {
    case exited(Int32)
    case signaled(Int32)

    init(waitStatus status: Int32) {
        // WIFEXITED / WEXITSTATUS / WTERMSIG, which Swift does not import.
        if status & 0x7F == 0 {
            self = .exited((status >> 8) & 0xFF)
        } else {
            self = .signaled(status & 0x7F)
        }
    }

    package var description: String {
        switch self {
        case .exited(let code): "exit code \(code)"
        case .signaled(let signal): "signal \(signal)"
        }
    }
}

/// The app process. It inherits standard input, output and error, so its output reaches Vercel's
/// logs directly.
package final class ChildProcess: Sendable {
    package let pid: pid_t

    private init(pid: pid_t) {
        self.pid = pid
    }

    /// Starts `path` with `environment`. Signal dispositions and the signal mask are reset, so the
    /// app gets default `SIGTERM`/`SIGINT` handling even though the bootstrap handles them itself.
    package static func spawn(path: String, environment: [(String, String)]) throws -> ChildProcess {
        let argv = [strdup(path)] + [UnsafeMutablePointer<CChar>?(nil)]
        let envp = environment.map { strdup("\($0.0)=\($0.1)") } + [UnsafeMutablePointer<CChar>?(nil)]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        #if canImport(Darwin)
        var attributes: posix_spawnattr_t?
        #else
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, nil, &attributes, argv, envp)
        guard result == 0 else {
            throw BootstrapError("cannot start \(path): \(String(cString: strerror(result)))")
        }
        return ChildProcess(pid: pid)
    }

    package func signal(_ signal: Int32) {
        _ = kill(pid, signal)
    }

    /// The exit status if the process has exited, without waiting. Call on `SIGCHLD`.
    package func reap() -> ExitStatus? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return ExitStatus(waitStatus: status) }
            if result < 0, errno == EINTR { continue }
            return nil
        }
    }
}
