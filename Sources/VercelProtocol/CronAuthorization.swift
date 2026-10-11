package import HTTPTypes

/// The Vercel Cron Jobs authorization check, shared by `VercelBootstrap` (which rejects
/// unauthorized requests to cron paths) and the public `VercelCron` API.
package enum CronAuthorization {
    /// The JSON body of the `401` response for unauthorized cron requests.
    package static let unauthorizedBody = #"{"error":"unauthorized"}"#

    /// Whether a request may run a cron job: always without a secret, otherwise only with
    /// `Authorization: Bearer <secret>`.
    package static func isAuthorized(_ headers: HTTPFields, secret: String?) -> Bool {
        guard let secret, !secret.isEmpty else { return true }
        guard let authorization = headers[.authorization] else { return false }
        return constantTimeEquals(authorization, "Bearer \(secret)")
    }
}

/// Compares without short-circuiting on the first differing byte.
package func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
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
