public import HTTPTypes
import VercelProtocol

/// Vercel Cron Jobs support.
///
/// Declare crons in `vercel.json` next to `Package.swift`; the `vercel` plugin copies them
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
    public static let unauthorizedBody = CronAuthorization.unauthorizedBody

    /// Whether a request may run a cron job.
    ///
    /// Without a secret every request is allowed; set `CRON_SECRET` in the project to lock cron
    /// routes down.
    public static func isAuthorized(_ headers: HTTPFields, secret: String? = VercelEnvironment.current.cronSecret) -> Bool {
        CronAuthorization.isAuthorized(headers, secret: secret)
    }
}
