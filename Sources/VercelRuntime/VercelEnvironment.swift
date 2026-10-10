/// Vercel's system environment variables, typed.
///
/// Matches `getEnv()` from `@vercel/functions`: empty values are treated as unset. System
/// environment variables must be exposed in the project settings to be available at runtime.
public struct VercelEnvironment: Sendable {
    /// The deployment environment (`VERCEL_ENV`).
    public enum Target: String, Sendable {
        case production
        case preview
        case development
    }

    /// Git metadata for the deployment (`VERCEL_GIT_*`).
    public struct Git: Sendable {
        public var provider: String?
        public var repoSlug: String?
        public var repoOwner: String?
        public var repoID: String?
        public var commitRef: String?
        public var commitSHA: String?
        public var commitMessage: String?
        public var commitAuthorLogin: String?
        public var commitAuthorName: String?
        public var previousSHA: String?
        public var pullRequestID: String?
    }

    /// Every variable this type reads.
    public static let variableNames = [
        "VERCEL", "CI", "VERCEL_ENV", "VERCEL_URL", "VERCEL_BRANCH_URL", "VERCEL_PROJECT_PRODUCTION_URL",
        "VERCEL_REGION", "VERCEL_DEPLOYMENT_ID", "VERCEL_SKEW_PROTECTION_ENABLED",
        "VERCEL_AUTOMATION_BYPASS_SECRET", "VERCEL_GIT_PROVIDER", "VERCEL_GIT_REPO_SLUG",
        "VERCEL_GIT_REPO_OWNER", "VERCEL_GIT_REPO_ID", "VERCEL_GIT_COMMIT_REF", "VERCEL_GIT_COMMIT_SHA",
        "VERCEL_GIT_COMMIT_MESSAGE", "VERCEL_GIT_COMMIT_AUTHOR_LOGIN", "VERCEL_GIT_COMMIT_AUTHOR_NAME",
        "VERCEL_GIT_PREVIOUS_SHA", "VERCEL_GIT_PULL_REQUEST_ID", "VERCEL_OIDC_TOKEN", "CRON_SECRET",
    ]

    private let values: [String: String]

    /// An environment from explicit values, for tests.
    public init(values: [String: String]) {
        self.values = values.filter { !$0.value.isEmpty }
    }

    /// The process environment.
    public static var current: VercelEnvironment {
        var values: [String: String] = [:]
        for name in variableNames {
            values[name] = environmentValue(name)
        }
        return VercelEnvironment(values: values)
    }

    public subscript(_ name: String) -> String? {
        values[name]
    }

    /// Whether the code is running on Vercel (`VERCEL=1`).
    public var isVercel: Bool { self["VERCEL"] == "1" }
    public var target: Target? { self["VERCEL_ENV"].flatMap(Target.init(rawValue:)) }
    /// The deployment URL without a scheme, for example `my-app-abc123.vercel.app`.
    public var url: String? { self["VERCEL_URL"] }
    public var branchURL: String? { self["VERCEL_BRANCH_URL"] }
    public var projectProductionURL: String? { self["VERCEL_PROJECT_PRODUCTION_URL"] }
    /// The region running the function, for example `iad1`.
    public var region: String? { self["VERCEL_REGION"] }
    public var deploymentID: String? { self["VERCEL_DEPLOYMENT_ID"] }
    public var isSkewProtectionEnabled: Bool { self["VERCEL_SKEW_PROTECTION_ENABLED"] == "1" }
    public var automationBypassSecret: String? { self["VERCEL_AUTOMATION_BYPASS_SECRET"] }
    /// Process-level OIDC token. Prefer `request.headers.vercel.oidcToken`, which is per request.
    public var oidcToken: String? { self["VERCEL_OIDC_TOKEN"] }
    /// The secret Vercel sends with cron requests (`Authorization: Bearer <CRON_SECRET>`).
    public var cronSecret: String? { self["CRON_SECRET"] }

    public var git: Git {
        Git(
            provider: self["VERCEL_GIT_PROVIDER"],
            repoSlug: self["VERCEL_GIT_REPO_SLUG"],
            repoOwner: self["VERCEL_GIT_REPO_OWNER"],
            repoID: self["VERCEL_GIT_REPO_ID"],
            commitRef: self["VERCEL_GIT_COMMIT_REF"],
            commitSHA: self["VERCEL_GIT_COMMIT_SHA"],
            commitMessage: self["VERCEL_GIT_COMMIT_MESSAGE"],
            commitAuthorLogin: self["VERCEL_GIT_COMMIT_AUTHOR_LOGIN"],
            commitAuthorName: self["VERCEL_GIT_COMMIT_AUTHOR_NAME"],
            previousSHA: self["VERCEL_GIT_PREVIOUS_SHA"],
            pullRequestID: self["VERCEL_GIT_PULL_REQUEST_ID"]
        )
    }
}
