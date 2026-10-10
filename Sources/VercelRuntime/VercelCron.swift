public import HTTPTypes

/// Vercel Cron Jobs support.
///
/// Declare crons in `vercel.json` next to `Package.swift`; the `vercel-build` plugin copies them
/// into the deployment:
///
/// ```json
/// { "crons": [{ "path": "/cron/cleanup", "schedule": "0 5 * * *" }] }
/// ```
///
/// Vercel calls the path with `GET`. When the project has a `CRON_SECRET` environment variable,
/// it sends `Authorization: Bearer <CRON_SECRET>`, and `VercelBootstrap` rejects requests to the
/// cron paths without it before they reach your server. ``isAuthorized(_:secret:)`` is the same
/// check, for routes you trigger some other way.
public enum VercelCron {
    /// The JSON body of the `401` response for unauthorized cron requests.
    public static let unauthorizedBody = #"{"error":"unauthorized"}"#

    /// Whether a request may run a cron job.
    ///
    /// Without a secret every request is allowed; set `CRON_SECRET` in the project to lock cron
    /// routes down.
    public static func isAuthorized(_ headers: HTTPFields, secret: String? = VercelEnvironment.current.cronSecret) -> Bool {
        guard let secret, !secret.isEmpty else { return true }
        guard let authorization = headers[.authorization] else { return false }
        return constantTimeEquals(authorization, "Bearer \(secret)")
    }
}

/// Compares without short-circuiting on the first differing byte.
func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
    for index in 0..<max(left.count, right.count) {
        let a = index < left.count ? left[index] : 0
        let b = index < right.count ? right[index] : 0
        difference |= a ^ b
    }
    return difference == 0 && left.count == right.count
}
