#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// A Vercel OIDC token (a JWT) with its claims decoded.
///
/// The signature is not verified: the token comes from Vercel (the request header or
/// `VERCEL_OIDC_TOKEN`), and the services you send it to verify it. Use the claims to inspect the
/// token, for example to log which project and environment it was issued for or to check whether
/// it expired.
///
/// ```swift
/// let token = try VercelOIDCToken(OIDC.token())
/// print(token.projectID ?? "-", token.environment ?? "-", token.expiresAt ?? "-")
/// if token.isExpired() {
///     // Locally: run `vercel env pull` again.
/// }
/// ```
///
/// Printing a token, `dump` and debug descriptions show its claims but never ``rawValue``.
public struct VercelOIDCToken: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The encoded token, to send to other services. Keep it secret: descriptions of the token
    /// leave it out.
    public let rawValue: String
    /// `iss`, for example `https://oidc.vercel.com/acme`.
    public let issuer: String?
    /// `sub`, for example `owner:acme:project:my-app:environment:production`.
    public let subject: String?
    /// `aud`: one or more audiences, for example `["https://vercel.com/acme"]`.
    public let audience: [String]
    /// `exp`: when the token expires.
    public let expiresAt: Date?
    /// `iat`: when the token was issued.
    public let issuedAt: Date?
    /// `owner`: the team slug.
    public let owner: String?
    /// `owner_id`: the team id, for example `team_abc123`.
    public let ownerID: String?
    /// `project`: the project name.
    public let project: String?
    /// `project_id`: the project id, for example `prj_abc123`.
    public let projectID: String?
    /// `environment`: `production`, `preview` or `development`.
    public let environment: String?

    /// Decodes the claims of `rawValue`, a JWT (`header.payload.signature`).
    ///
    /// - Throws: ``VercelOIDCError/malformedToken(reason:)`` if `rawValue` does not have three
    ///   segments or its payload is not a base64url-encoded JSON object.
    public init(_ rawValue: String) throws(VercelOIDCError) {
        let segments = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else {
            throw .malformedToken(reason: "expected 3 segments separated by '.', found \(segments.count)")
        }
        guard let payload = base64URLDecoded(segments[1]) else {
            throw .malformedToken(reason: "the payload is not valid base64url")
        }
        let claims: Claims
        do {
            claims = try JSONDecoder().decode(Claims.self, from: Data(payload))
        } catch {
            throw .malformedToken(reason: "the payload is not a JSON object")
        }
        self.rawValue = rawValue
        issuer = claims.iss
        subject = claims.sub
        audience = claims.aud ?? []
        expiresAt = claims.exp.map { Date(timeIntervalSince1970: $0) }
        issuedAt = claims.iat.map { Date(timeIntervalSince1970: $0) }
        owner = claims.owner
        ownerID = claims.owner_id
        project = claims.project
        projectID = claims.project_id
        environment = claims.environment
    }

    /// Whether the token has expired at `date`. `false` without an `exp` claim.
    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    /// The claims, without the encoded token, so printing a token does not leak it.
    public var description: String {
        var parts: [String] = []
        if let issuer { parts.append("issuer: \(issuer)") }
        if let subject { parts.append("subject: \(subject)") }
        if !audience.isEmpty { parts.append("audience: \(audience)") }
        if let expiresAt { parts.append("expiresAt: \(expiresAt)") }
        return "VercelOIDCToken(\(parts.joined(separator: ", ")))"
    }

    public var debugDescription: String { description }

    /// The claims for `dump` and debuggers, with the encoded token redacted.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "rawValue": "<redacted>",
                "issuer": issuer as Any,
                "subject": subject as Any,
                "audience": audience,
                "expiresAt": expiresAt as Any,
                "issuedAt": issuedAt as Any,
                "owner": owner as Any,
                "ownerID": ownerID as Any,
                "project": project as Any,
                "projectID": projectID as Any,
                "environment": environment as Any,
            ],
            displayStyle: .struct
        )
    }
}

/// The JWT claims ``VercelOIDCToken`` exposes. Claims with an unexpected type are ignored rather
/// than failing the whole token.
private struct Claims: Decodable {
    var iss: String?
    var sub: String?
    var aud: [String]?
    var exp: Double?
    var iat: Double?
    var owner: String?
    var owner_id: String?
    var project: String?
    var project_id: String?
    var environment: String?

    private enum CodingKeys: String, CodingKey {
        case iss, sub, aud, exp, iat, owner, owner_id, project, project_id, environment
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { try? container.decodeIfPresent(String.self, forKey: key) }
        func number(_ key: CodingKeys) -> Double? { try? container.decodeIfPresent(Double.self, forKey: key) }
        iss = string(.iss)
        sub = string(.sub)
        // `aud` is a string or an array of strings (RFC 7519 §4.1.3).
        aud = string(.aud).map { [$0] } ?? (try? container.decodeIfPresent([String].self, forKey: .aud))
        exp = number(.exp)
        iat = number(.iat)
        owner = string(.owner)
        owner_id = string(.owner_id)
        project = string(.project)
        project_id = string(.project_id)
        environment = string(.environment)
    }
}
