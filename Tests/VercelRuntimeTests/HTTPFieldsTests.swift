import HTTPTypes
import Testing
import VercelProtocol
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

    @Test func exposesTheDeadlineReplacingClientValues() throws {
        var fields = HTTPFields()
        fields[try #require(HTTPField.Name("x-vercel-deadline"))] = "spoofed"
        fields[try #require(HTTPField.Name("x-vercel-internal-invocation-id"))] = "inv"
        fields[try #require(HTTPField.Name("x-vercel-internal-deadline"))] = "2026-10-11T17:00:00.123Z"
        fields[try #require(HTTPField.Name("accept"))] = "*/*"

        _ = fields.removeVercelInternalFields()

        #expect(fields.map(\.name.canonicalName) == ["accept", "x-vercel-deadline"])
        #expect(fields[try #require(HTTPField.Name("x-vercel-deadline"))] == "2026-10-11T17:00:00.123Z")
    }

    @Test func stripsClientDeadlineWithoutARuntimeOne() throws {
        var fields = HTTPFields()
        fields[try #require(HTTPField.Name("X-Vercel-Deadline"))] = "spoofed"
        fields[try #require(HTTPField.Name("accept"))] = "*/*"

        #expect(fields.removeVercelInternalFields() == nil)
        #expect(fields.map(\.name.canonicalName) == ["accept"])
    }

    @Test func returnsHiddenRuntimeCacheFields() throws {
        var fields = HTTPFields()
        fields[try #require(HTTPField.Name("x-vercel-internal-invocation-id"))] = "inv"
        fields[try #require(HTTPField.Name("x-vercel-sc-runtime-cache"))] = "1"
        fields[try #require(HTTPField.Name("x-vercel-sc-headers"))] = #"{"authorization":"Bearer x"}"#
        fields[try #require(HTTPField.Name("X-Vercel-SC-Host"))] = "cache.internal"
        fields[try #require(HTTPField.Name("x-vercel-sc-basepath"))] = "/v1"
        fields[try #require(HTTPField.Name("x-vercel-sc-protocol"))] = "https"
        fields[try #require(HTTPField.Name("x-vercel-sc-no-header-leak"))] = "1"

        let extracted = fields.extractVercelInternalFields()

        #expect(fields.isEmpty)
        #expect(extracted.invocation?.invocationID == "inv")
        #expect(
            extracted.hiddenRuntimeCacheFields == [
                "x-vercel-sc-headers": #"{"authorization":"Bearer x"}"#,
                "x-vercel-sc-host": "cache.internal",
                "x-vercel-sc-basepath": "/v1",
                "x-vercel-sc-protocol": "https",
            ]
        )
    }

    /// Repeated `x-vercel-sc-*` headers: hidden values are joined exactly like the app's
    /// `HTTPFields` subscript joins visible ones, so both modes resolve the same configuration.
    @Test func repeatedHiddenRuntimeCacheFieldsMatchVisibleOnes() throws {
        let pairs = [
            ("x-vercel-internal-invocation-id", "inv"),
            ("x-vercel-sc-host", "a.internal"),
            ("x-vercel-sc-headers", #"{"authorization":"Bearer a"}"#),
            ("X-Vercel-SC-Host", "b.internal"),
            ("x-vercel-sc-headers", #"{"authorization":"Bearer b"}"#),
            ("x-vercel-sc-basepath", "/base"),
        ]
        var visible = HTTPFields(pairs)
        var hidden = HTTPFields(pairs + [("x-vercel-sc-no-header-leak", "1")])
        #expect(visible.extractVercelInternalFields().hiddenRuntimeCacheFields == [:])
        let extracted = hidden.extractVercelInternalFields().hiddenRuntimeCacheFields
        #expect(hidden.isEmpty)

        #expect(extracted["x-vercel-sc-host"] == "a.internal, b.internal")
        for name in VercelHeader.runtimeCacheFields {
            #expect(extracted[name] == visible[try #require(HTTPField.Name(name))], "\(name)")
        }
        // Joined JSON objects are no configuration, in both modes.
        #expect(RuntimeCacheConfiguration(fields: extracted) == nil)
    }

    @Test func doesNotExposeAnEmptyDeadline() throws {
        var fields = HTTPFields([
            ("x-vercel-deadline", "spoofed"), ("x-vercel-internal-invocation-id", "inv"),
            ("x-vercel-internal-deadline", ""), ("accept", "*/*"),
        ])
        _ = fields.removeVercelInternalFields()
        #expect(fields.map(\.name.canonicalName) == ["accept"])
    }

    @Test func visibleRuntimeCacheFieldsAreNotReturned() throws {
        var fields = HTTPFields()
        fields[try #require(HTTPField.Name("x-vercel-sc-host"))] = "cache.internal"

        let extracted = fields.extractVercelInternalFields()

        #expect(fields.map(\.name.canonicalName) == ["x-vercel-sc-host"])
        #expect(extracted == VercelInternalFields(invocation: nil))
    }

    @Test func untouchedWithoutInternalFields() throws {
        var fields = HTTPFields()
        fields[try #require(HTTPField.Name("accept"))] = "*/*"
        let before = fields

        #expect(fields.removeVercelInternalFields() == nil)
        #expect(fields == before)
    }
}
