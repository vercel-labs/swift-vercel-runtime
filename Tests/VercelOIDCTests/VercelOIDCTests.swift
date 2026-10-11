#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import Testing
import VercelHTTP
import VercelRuntime
@testable import VercelOIDC

@Suite struct TokenLookupTests {
    let transport = MockHTTPTransport(responses: [])

    @Test func explicitHeadersWin() async throws {
        let client = makeClient(transport, environment: ["VERCEL_OIDC_TOKEN": "env"])
        let explicit = HTTPFields([("x-vercel-oidc-token", "explicit")])
        try await Vercel.withRequest(HTTPFields([("x-vercel-oidc-token", "current")])) { () throws in
            #expect(try client.token(headers: explicit) == "explicit")
            #expect(try OIDC.token(headers: explicit) == "explicit")
        }
    }

    @Test func currentRequestIsUsedWithoutExplicitHeaders() async throws {
        let client = makeClient(transport, environment: ["VERCEL_OIDC_TOKEN": "env"])
        try await Vercel.withRequest(HTTPFields([("x-vercel-oidc-token", "current")])) { () throws in
            #expect(try client.token(headers: nil) == "current")
        }
    }

    @Test func environmentIsTheFallback() async throws {
        let client = makeClient(transport, environment: ["VERCEL_OIDC_TOKEN": "env"])
        #expect(try client.token(headers: nil) == "env")
        // Explicit headers without the token fall back to the environment, not the current request.
        try await Vercel.withRequest(HTTPFields([("x-vercel-oidc-token", "current")])) { () throws in
            #expect(try client.token(headers: HTTPFields([("x-vercel-id", "iad1::1")])) == "env")
        }
        // An empty header counts as missing.
        #expect(try client.token(headers: HTTPFields([("x-vercel-oidc-token", "")])) == "env")
        await Vercel.withRequest(HTTPFields([("x-vercel-id", "iad1::1")])) {
            #expect((try? client.token(headers: nil)) == "env")
        }
    }

    @Test func missingEverywhereThrows() async {
        let client = makeClient(transport)
        #expect(throws: VercelOIDCError.missingToken) { try client.token(headers: nil) }
        await Vercel.withRequest(HTTPFields([("x-vercel-id", "iad1::1")])) { () -> Void in
            #expect(throws: VercelOIDCError.missingToken) { try client.token(headers: nil) }
        }
        #expect(throws: VercelOIDCError.missingToken) { try client.token(headers: [:]) }
    }
}

@Suite struct TokenClaimsTests {
    @Test func decodesVercelClaims() throws {
        let jwt = makeJWT("""
            {"iss":"https://oidc.vercel.com/acme","sub":"owner:acme:project:my-app:environment:production",\
            "aud":"https://vercel.com/acme","exp":1791738000,"iat":1791734400,"nbf":1791734400,\
            "owner":"acme","owner_id":"team_123","project":"my-app","project_id":"prj_456",\
            "environment":"production","scope":"owner:acme:project:my-app:environment:production"}
            """)
        let token = try VercelOIDCToken(jwt)
        #expect(token.rawValue == jwt)
        #expect(token.issuer == "https://oidc.vercel.com/acme")
        #expect(token.subject == "owner:acme:project:my-app:environment:production")
        #expect(token.audience == ["https://vercel.com/acme"])
        #expect(token.expiresAt == Date(timeIntervalSince1970: 1_791_738_000))
        #expect(token.issuedAt == testNow)
        #expect(token.owner == "acme")
        #expect(token.ownerID == "team_123")
        #expect(token.project == "my-app")
        #expect(token.projectID == "prj_456")
        #expect(token.environment == "production")
        #expect(!token.isExpired(at: testNow))
        #expect(token.isExpired(at: Date(timeIntervalSince1970: 1_791_738_000)))
        #expect(!token.description.contains(jwt))
        #expect(token.description.contains("https://oidc.vercel.com/acme"))
    }

    @Test func audienceArrayFractionalExpiryAndMissingClaims() throws {
        let token = try VercelOIDCToken(makeJWT(#"{"aud":["a","b"],"exp":1791738000.5}"#))
        #expect(token.audience == ["a", "b"])
        #expect(token.expiresAt == Date(timeIntervalSince1970: 1_791_738_000.5))
        #expect(token.issuer == nil && token.subject == nil && token.projectID == nil && token.ownerID == nil)
        #expect(token.environment == nil && token.issuedAt == nil)

        let empty = try VercelOIDCToken(makeJWT("{}"))
        #expect(empty.audience.isEmpty)
        #expect(empty.expiresAt == nil)
        #expect(!empty.isExpired())
    }

    @Test func claimsWithUnexpectedTypesAreIgnored() throws {
        let token = try VercelOIDCToken(makeJWT(#"{"iss":42,"exp":"soon","aud":{"x":1},"project_id":"prj_1"}"#))
        #expect(token.issuer == nil)
        #expect(token.expiresAt == nil)
        #expect(token.audience.isEmpty)
        #expect(token.projectID == "prj_1")
    }

    /// Payload lengths 0, 1 and 2 mod 3 encode without padding as 0, 2 and 3 characters mod 4.
    @Test(arguments: [#"{"sub":"a"}"#, #"{"sub":"ab"}"#, #"{"sub":"abc"}"#])
    func decodesEveryPaddingLength(payload: String) throws {
        let subject = try JSONDecoder().decode([String: String].self, from: Data(payload.utf8))["sub"]
        let unpadded = base64URLEncoded(Array(payload.utf8))
        let padded = base64URLEncoded(Array(payload.utf8), padded: true)
        #expect(try VercelOIDCToken("h.\(unpadded).s").subject == subject)
        #expect(try VercelOIDCToken("h.\(padded).s").subject == subject)
    }

    @Test func base64URLUsesTheURLAlphabet() {
        // 0xfb 0xff 0xfe -> "-__-" in base64url, "+//+" in standard base64.
        #expect(base64URLDecoded("-__-") == [0xFB, 0xFF, 0xFE])
        #expect(base64URLDecoded("+//+") == [0xFB, 0xFF, 0xFE])
        #expect(base64URLDecoded("") == [])
        #expect(base64URLDecoded("YQ") == Array("a".utf8))
        #expect(base64URLDecoded("YQ==") == Array("a".utf8))
        #expect(base64URLDecoded("YWI") == Array("ab".utf8))
        #expect(base64URLDecoded("YWI=") == Array("ab".utf8))
        #expect(base64URLDecoded("YWJj") == Array("abc".utf8))
        // One character left over, wrong padding, or characters outside the alphabet.
        #expect(base64URLDecoded("YWJjZ") == nil)
        #expect(base64URLDecoded("YQ=") == nil)
        #expect(base64URLDecoded("YWJj=") == nil)
        #expect(base64URLDecoded("YW J") == nil)
        #expect(base64URLDecoded("YW.J") == nil)
    }

    @Test(arguments: [
        ("", "expected 3 segments separated by '.', found 1"),
        ("a.b", "expected 3 segments separated by '.', found 2"),
        ("a.b.c.d", "expected 3 segments separated by '.', found 4"),
        ("h.e30!.s", "the payload is not valid base64url"),
        ("h.YWJjZ.s", "the payload is not valid base64url"),
        ("h.bm90IGpzb24.s", "the payload is not a JSON object"), // "not json"
        ("h.WzEsMl0.s", "the payload is not a JSON object"), // [1,2]
        ("h..s", "the payload is not a JSON object"),
    ])
    func rejectsMalformedTokens(token: String, reason: String) {
        #expect(throws: VercelOIDCError.malformedToken(reason: reason)) { try VercelOIDCToken(token) }
    }
}
