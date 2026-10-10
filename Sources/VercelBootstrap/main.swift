#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import VercelBootstrapCore

// The entrypoint of every Swift function deployed with `vercel-build`. See `Bootstrap`.
exit(await Bootstrap.run())
