import HTTPTypes
import Testing
import VercelRuntime

@Suite struct HTTPFieldsTests {
    @Test func stripsInternalFieldsAndExtractsContext() throws {
        var fields = HTTPFields()
        fields[try #require(HTTPField.Name("host"))] = "example.com"
        fields[try #require(HTTPField.Name("X-Vercel-Internal-Invocation-Id"))] = "inv-9"
        fields[try #require(HTTPField.Name("x-vercel-internal-request-id"))] = "9"
        fields[try #require(HTTPField.Name("x-vercel-internal-trace-id"))] = "trace"
        fields[try #require(HTTPField.Name("x-vercel-internal-span-id"))] = "span"
        fields[try #require(HTTPField.Name("x-vercel-id"))] = "iad1::abc"

        let context = fields.removeVercelInternalFields()

        #expect(context == InvocationContext(invocationID: "inv-9", requestID: 9))
        #expect(fields.map(\.name.canonicalName) == ["host", "x-vercel-id"])
    }

    @Test func exposesInternalOIDCTokenWhenPublicOneIsMissing() throws {
        var fields = HTTPFields()
        fields[try #require(HTTPField.Name("x-vercel-internal-invocation-id"))] = "inv"
        fields[try #require(HTTPField.Name("x-vercel-internal-oidc-token"))] = "token-1"

        _ = fields.removeVercelInternalFields()

        #expect(fields[try #require(HTTPField.Name("x-vercel-oidc-token"))] == "token-1")
        #expect(fields.count == 1)
    }

    @Test func keepsExistingPublicOIDCToken() throws {
        var fields = HTTPFields()
        fields[try #require(HTTPField.Name("x-vercel-oidc-token"))] = "public"
        fields[try #require(HTTPField.Name("x-vercel-internal-oidc-token"))] = "internal"

        _ = fields.removeVercelInternalFields()

        #expect(fields[try #require(HTTPField.Name("x-vercel-oidc-token"))] == "public")
        #expect(fields.count == 1)
    }

    @Test func alwaysStripsRuntimeCacheHeader() throws {
        var fields = HTTPFields()
        fields[try #require(HTTPField.Name("x-vercel-sc-runtime-cache"))] = "1"
        fields[try #require(HTTPField.Name("x-vercel-sc-host"))] = "cache.internal"
        fields[try #require(HTTPField.Name("accept"))] = "*/*"

        #expect(fields.removeVercelInternalFields() == nil)
        #expect(fields.map(\.name.canonicalName) == ["accept", "x-vercel-sc-host"])
    }

    @Test func stripsRuntimeCacheConfigurationWhenProxyAsks() throws {
        var fields = HTTPFields()
        fields[try #require(HTTPField.Name("x-vercel-internal-invocation-id"))] = "inv"
        fields[try #require(HTTPField.Name("x-vercel-sc-headers"))] = #"{"authorization":"Bearer x"}"#
        fields[try #require(HTTPField.Name("x-vercel-sc-host"))] = "cache.internal"
        fields[try #require(HTTPField.Name("x-vercel-sc-basepath"))] = "/v1"
        fields[try #require(HTTPField.Name("x-vercel-sc-protocol"))] = "https"
        fields[try #require(HTTPField.Name("x-vercel-sc-no-header-leak"))] = "1"
        fields[try #require(HTTPField.Name("accept"))] = "*/*"

        #expect(fields.removeVercelInternalFields()?.invocationID == "inv")
        #expect(fields.map(\.name.canonicalName) == ["accept"])
    }

    @Test func untouchedWithoutInternalFields() throws {
        var fields = HTTPFields()
        fields[try #require(HTTPField.Name("accept"))] = "*/*"
        let before = fields

        #expect(fields.removeVercelInternalFields() == nil)
        #expect(fields == before)
    }
}
