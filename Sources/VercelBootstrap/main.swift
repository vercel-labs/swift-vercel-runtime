#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import VercelBootstrapCore

// The entrypoint of every Swift function deployed with `swift package vercel`. See `Bootstrap`.
exit(await Bootstrap.run())
