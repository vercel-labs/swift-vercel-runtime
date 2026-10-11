#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
package import VercelRuntime

extension VercelEnvironment {
    /// The environment variables the rate limit check reads.
    static let firewallVariableNames = [
        "VERCEL", "VERCEL_ENV", "VERCEL_AUTOMATION_BYPASS_SECRET", "RATE_LIMIT_SECRET",
        "PUBLIC_VERCEL_FIREWALL_PATH_PREFIX", "NEXT_PUBLIC_VERCEL_FIREWALL_PATH_PREFIX",
    ]

    /// The process environment, including the firewall variables ``VercelEnvironment/current``
    /// does not read.
    package static var firewall: VercelEnvironment {
        var values: [String: String] = [:]
        for name in firewallVariableNames {
            if let value = getenv(name) {
                values[name] = String(cString: value)
            }
        }
        return VercelEnvironment(values: values)
    }

    /// Whether to treat this process as development, where `@vercel/firewall` checks
    /// `NODE_ENV !== 'production'`: when not running on Vercel (`VERCEL` is not `1`), or when
    /// `VERCEL_ENV` is `development` (`vercel dev`, or variables from `vercel env pull`).
    var isFirewallDevelopment: Bool {
        !isVercel || target == .development
    }

    /// `PUBLIC_VERCEL_FIREWALL_PATH_PREFIX`, else `NEXT_PUBLIC_VERCEL_FIREWALL_PATH_PREFIX`, with a
    /// leading `/`; empty when neither is set.
    var firewallPathPrefix: String {
        guard let prefix = self["PUBLIC_VERCEL_FIREWALL_PATH_PREFIX"] ?? self["NEXT_PUBLIC_VERCEL_FIREWALL_PATH_PREFIX"] else {
            return ""
        }
        return prefix.utf8.first == UInt8(ascii: "/") ? prefix : "/" + prefix
    }
}
