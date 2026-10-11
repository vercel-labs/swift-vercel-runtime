#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import Synchronization
import Testing
import VercelHTTP
import VercelRuntime
@testable import VercelOIDC

/// The sample response from the AWS STS API reference for `AssumeRoleWithWebIdentity`.
let stsSampleResponse = """
    <AssumeRoleWithWebIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
      <AssumeRoleWithWebIdentityResult>
        <SubjectFromWebIdentityToken>amzn1.account.AF6RHO7KZU5XRVQJGXK6HB56KR2A</SubjectFromWebIdentityToken>
        <Audience>client.5498841531868486423.1548@apps.example.com</Audience>
        <AssumedRoleUser>
          <Arn>arn:aws:sts::123456789012:assumed-role/FederatedWebIdentityRole/app1</Arn>
          <AssumedRoleId>AROACLKWSDQRAOEXAMPLE:app1</AssumedRoleId>
        </AssumedRoleUser>
        <Credentials>
          <SessionToken>AQoDYXdzEE0a8ANXXXXXXXXNO1ewxE5TijQyp+IEXAMPLE</SessionToken>
          <SecretAccessKey>wJalrXUtnFEMI/K7MDENG/bPxRfiCYzEXAMPLEKEY</SecretAccessKey>
          <Expiration>2014-10-24T23:00:23Z</Expiration>
          <AccessKeyId>ASgeIAIOSFODNN7EXAMPLE</AccessKeyId>
        </Credentials>
        <SourceIdentity>SourceIdentityValue</SourceIdentity>
        <Provider>www.amazon.com</Provider>
      </AssumeRoleWithWebIdentityResult>
      <ResponseMetadata>
        <RequestId>ad4156e9-bce1-11e2-82e6-6b6efEXAMPLE</RequestId>
      </ResponseMetadata>
    </AssumeRoleWithWebIdentityResponse>
    """

/// An STS success response with `accessKeyID`, expiring at `expiration`.
func stsResponse(accessKeyID: String = "ASIAEXAMPLE", expiration: String = "2026-10-11T17:00:00Z") -> MockHTTPTransport.Response {
    .init(status: .ok, headerFields: [.contentType: "text/xml"], body: """
        <AssumeRoleWithWebIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
          <AssumeRoleWithWebIdentityResult>
            <Credentials>
              <AccessKeyId>\(accessKeyID)</AccessKeyId>
              <SecretAccessKey>secret</SecretAccessKey>
              <SessionToken>session</SessionToken>
              <Expiration>\(expiration)</Expiration>
            </Credentials>
          </AssumeRoleWithWebIdentityResult>
        </AssumeRoleWithWebIdentityResponse>
        """)
}

let roleARN = "arn:aws:iam::123456789012:role/my-app"
let encodedRoleARN = "arn%3Aaws%3Aiam%3A%3A123456789012%3Arole%2Fmy-app"

@Suite struct STSRequestTests {
    @Test func sendsAssumeRoleWithWebIdentity() async throws {
        let transport = MockHTTPTransport(responses: [stsResponse()])
        let client = makeClient(transport)
        let token = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.sig-_+/="
        let parameters = AssumeRoleParameters(roleARN: roleARN, region: "us-west-2", sessionName: "my session@1", durationSeconds: 900)

        let credentials = try await client.awsCredentials(parameters, headers: HTTPFields([("x-vercel-oidc-token", token)]))
        #expect(credentials == AWSCredentials(
            accessKeyID: "ASIAEXAMPLE",
            secretAccessKey: "secret",
            sessionToken: "session",
            expiration: Date(timeIntervalSince1970: 1_791_738_000)
        ))

        let sent = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(sent.request.method == .post)
        #expect(sent.request.urlString == "https://sts.us-west-2.amazonaws.com/")
        #expect(sent.request.headerFields[.contentType] == "application/x-www-form-urlencoded; charset=utf-8")
        #expect(sent.request.headerFields[.authorization] == nil)
        let fields = formFields(sent.text)
        #expect(fields.map(\.0) == ["Action", "Version", "RoleArn", "RoleSessionName", "WebIdentityToken", "DurationSeconds"])
        #expect(fields.map(\.1) == [
            "AssumeRoleWithWebIdentity",
            "2011-06-15",
            encodedRoleARN,
            "my+session%401",
            "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.sig-_%2B%2F%3D",
            "900",
        ])
    }

    @Test func defaultSessionNameAndNoDuration() async throws {
        let transport = MockHTTPTransport(responses: [stsResponse()])
        let client = makeClient(transport, environment: ["VERCEL_OIDC_TOKEN": "env-token"])
        _ = try await client.awsCredentials(AssumeRoleParameters(roleARN: roleARN), headers: nil)

        let fields = Dictionary(uniqueKeysWithValues: formFields(transport.requests.first?.text))
        #expect(fields["DurationSeconds"] == nil)
        #expect(fields["WebIdentityToken"] == "env-token")
        let sessionName = try #require(fields["RoleSessionName"])
        #expect(sessionName.hasPrefix("vercel-"))
        #expect(sessionName.utf8.count == 23)
        #expect(sessionName.dropFirst(7).allSatisfy { $0.isHexDigit })
        #expect(randomSessionName() != randomSessionName())
    }

    @Test func endpointSelection() throws {
        let transport = MockHTTPTransport(responses: [])
        let withEnv = makeClient(transport, environment: ["AWS_REGION": "eu-central-1"])
        let withoutEnv = makeClient(transport)
        #expect(try withEnv.stsEndpoint(region: "us-east-1") == "https://sts.us-east-1.amazonaws.com")
        #expect(try withEnv.stsEndpoint(region: nil) == "https://sts.eu-central-1.amazonaws.com")
        #expect(try withEnv.stsEndpoint(region: "") == "https://sts.eu-central-1.amazonaws.com")
        #expect(try withoutEnv.stsEndpoint(region: nil) == "https://sts.amazonaws.com")
        #expect(try withoutEnv.stsEndpoint(region: "cn-north-1") == "https://sts.cn-north-1.amazonaws.com.cn")
        #expect(try withoutEnv.stsEndpoint(region: "us-gov-west-1") == "https://sts.us-gov-west-1.amazonaws.com")
        for invalid in ["us-east-1.evil.com", "US-EAST-1", "us east", "-us", "a/b"] {
            #expect(throws: VercelOIDCError.invalidRegion(invalid)) { try withoutEnv.stsEndpoint(region: invalid) }
        }
    }

    @Test func usesTheGlobalEndpointWithoutARegion() async throws {
        let transport = MockHTTPTransport(responses: [stsResponse()])
        let client = makeClient(transport)
        _ = try await client.awsCredentials(AssumeRoleParameters(roleARN: roleARN), headers: HTTPFields([("x-vercel-oidc-token", "t")]))
        #expect(transport.requests.first?.request.urlString == "https://sts.amazonaws.com/")
    }

    @Test func exchangesTheTokenFirstWithAnAudience() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(status: .ok, body: #"{"token":"exchanged","expiry":1791738000}"#),
            stsResponse(),
        ])
        let client = makeClient(transport)
        let parameters = AssumeRoleParameters(roleARN: roleARN, region: "us-east-1", audience: "sts.amazonaws.com", jti: "j1")
        _ = try await client.awsCredentials(parameters, headers: HTTPFields([("x-vercel-oidc-token", "source")]))

        #expect(transport.requests.count == 2)
        #expect(transport.requests[0].request.authority == "oidc.vercel.com")
        #expect(try jsonObject(transport.requests[0].body) == ["token": "source", "aud": "sts.amazonaws.com", "jti": "j1"])
        let fields = Dictionary(uniqueKeysWithValues: formFields(transport.requests[1].text))
        #expect(fields["WebIdentityToken"] == "exchanged")
    }

    @Test func readsTheTokenFromTheCurrentRequest() async throws {
        let transport = MockHTTPTransport(responses: [stsResponse()])
        let client = makeClient(transport, environment: ["VERCEL_OIDC_TOKEN": "env"])
        _ = try await Vercel.withRequest(HTTPFields([("x-vercel-oidc-token", "current")])) {
            try await client.awsCredentials(AssumeRoleParameters(roleARN: roleARN), headers: nil)
        }
        #expect(Dictionary(uniqueKeysWithValues: formFields(transport.requests.first?.text))["WebIdentityToken"] == "current")
    }

    @Test func failsWithoutATokenBeforeAnyRequest() async {
        let transport = MockHTTPTransport(responses: [])
        await #expect(throws: VercelOIDCError.missingToken) {
            try await makeClient(transport).awsCredentials(AssumeRoleParameters(roleARN: roleARN), headers: nil)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func stsErrorsThrowCodeAndMessage() async {
        let transport = MockHTTPTransport(responses: [
            .init(status: .badRequest, body: """
                <ErrorResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
                  <Error>
                    <Type>Sender</Type>
                    <Code>InvalidIdentityToken</Code>
                    <Message>No OpenIDConnect provider found in your account for https://oidc.vercel.com/acme &amp; &quot;more&quot; &lt;x&gt; &#39;y&#x27;</Message>
                  </Error>
                  <RequestId>c6104cbe-af31-11e0-8154-cbc7ccf896c7</RequestId>
                </ErrorResponse>
                """),
            .init(status: .serviceUnavailable, body: "<html>Service Unavailable</html>"),
        ])
        let client = makeClient(transport)
        let parameters = AssumeRoleParameters(roleARN: roleARN)
        let headers = HTTPFields([("x-vercel-oidc-token", "t")])
        await #expect(throws: VercelOIDCError.awsSTS(
            statusCode: 400,
            code: "InvalidIdentityToken",
            message: #"No OpenIDConnect provider found in your account for https://oidc.vercel.com/acme & "more" <x> 'y'"#
        )) {
            try await client.awsCredentials(parameters, headers: headers)
        }
        await #expect(throws: VercelOIDCError.awsSTS(statusCode: 503, code: nil, message: nil)) {
            try await client.awsCredentials(parameters, headers: headers)
        }
    }

    @Test func stsTimeoutsAndTransportFailures() async {
        struct Unreachable: Error {}
        let headers = HTTPFields([("x-vercel-oidc-token", "web-identity-secret")])
        let timingOut = makeClient(MockHTTPTransport { request in
            throw VercelHTTPError.timedOut(method: "POST", url: request.request.urlString, timeout: request.timeout)
        })
        await #expect(throws: VercelOIDCError.timedOut(.seconds(30))) {
            try await timingOut.awsCredentials(AssumeRoleParameters(roleARN: roleARN, region: "us-east-1"), headers: headers)
        }
        let failing = makeClient(MockHTTPTransport { _ in throw Unreachable() })
        let error = await #expect(throws: VercelOIDCError.self) {
            try await failing.awsCredentials(AssumeRoleParameters(roleARN: roleARN, region: "us-east-1"), headers: headers)
        }
        guard case .requestFailed(let reason)? = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(reason.hasPrefix("POST https://sts.us-east-1.amazonaws.com/ failed"))
        #expect(!reason.contains("web-identity-secret"))
    }

    @Test func reportsFetchesWithTheExplicitRequestHeaders() async throws {
        let reports = ReportRecorder()
        let headers = HTTPFields([("x-vercel-oidc-token", "t"), ("x-vercel-bootstrap-request", "7")])
        let client = makeClient(MockHTTPTransport(responses: [stsResponse()]), reportFetch: reports.record)
        _ = try await client.awsCredentials(AssumeRoleParameters(roleARN: roleARN, region: "us-east-1"), headers: headers)
        #expect(reports.all.map(\.incomingRequestHeaders) == [headers])
        #expect(reports.all.first?.host == "sts.us-east-1.amazonaws.com")
    }
}

@Suite struct STSResponseParsingTests {
    @Test func parsesTheAWSSampleResponse() throws {
        let credentials = try parseAssumeRoleResponse(Array(stsSampleResponse.utf8))
        #expect(credentials.accessKeyID == "ASgeIAIOSFODNN7EXAMPLE")
        #expect(credentials.secretAccessKey == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYzEXAMPLEKEY")
        #expect(credentials.sessionToken == "AQoDYXdzEE0a8ANXXXXXXXXNO1ewxE5TijQyp+IEXAMPLE")
        #expect(credentials.expiration == Date(timeIntervalSince1970: 1_414_191_623))
        #expect(credentials.assumedRoleARN == "arn:aws:sts::123456789012:assumed-role/FederatedWebIdentityRole/app1")
        #expect(!credentials.description.contains(credentials.secretAccessKey))
        #expect(!credentials.description.contains(credentials.sessionToken))
    }

    @Test func unescapesValues() throws {
        let body = """
            <R><Credentials><AccessKeyId>AK</AccessKeyId><SecretAccessKey>a&amp;b&lt;c&gt;&#x2F;&#47;&unknown;</SecretAccessKey>\
            <SessionToken><![CDATA[x&amp;y]]></SessionToken><Expiration>2026-10-11T17:00:00.5Z</Expiration></Credentials></R>
            """
        let credentials = try parseAssumeRoleResponse(Array(body.utf8))
        #expect(credentials.secretAccessKey == "a&b<c>//&unknown;")
        #expect(credentials.sessionToken == "x&amp;y")
        #expect(credentials.expiration == Date(timeIntervalSince1970: 1_791_738_000.5))
        #expect(credentials.assumedRoleARN == nil)
    }

    @Test(arguments: [
        ("<R></R>", "missing <Credentials>"),
        ("<R><Credentials/></R>", "missing <Expiration>"),
        ("<R><Credentials><Expiration>2026-10-11T17:00:00Z</Expiration></Credentials></R>", "missing <AccessKeyId>"),
        ("<R><Credentials><Expiration>tomorrow</Expiration></Credentials></R>", "invalid <Expiration> tomorrow"),
        ("<R><Credentials><AccessKeyId>A</AccessKeyId><SecretAccessKey>S</SecretAccessKey><Expiration>2026-10-11T17:00:00Z</Expiration></Credentials></R>", "missing <SessionToken>"),
    ])
    func rejectsIncompleteResponses(body: String, reason: String) {
        #expect(throws: VercelOIDCError.invalidSTSResponse(reason: reason)) { try parseAssumeRoleResponse(Array(body.utf8)) }
    }

    @Test func elementMatching() {
        let xml = Array(#"<a><Codes>no</Codes><Code attr="1" >yes</Code ><Empty/><Open>unterminated</a>"#.utf8)[...]
        #expect(xmlText("Code", in: xml) == "yes")
        #expect(xmlText("Codes", in: xml) == "no")
        #expect(xmlText("Empty", in: xml) == "")
        #expect(xmlText("Open", in: xml) == nil)
        #expect(xmlText("Missing", in: xml) == nil)
        #expect(xmlText("a", in: Array("<a>  padded\n</a>".utf8)[...]) == "padded")
    }

    @Test func errorParsingWithoutAnErrorElement() {
        let error = parseSTSError(Array("<Response><Code>Throttling</Code><Message>Rate exceeded</Message></Response>".utf8))
        #expect(error.code == "Throttling")
        #expect(error.message == "Rate exceeded")
        let empty = parseSTSError(Array("<Error><Code></Code></Error>".utf8))
        #expect(empty.code == nil && empty.message == nil)
    }

    @Test(arguments: [
        ("2014-10-24T23:00:23Z", 1_414_191_623.0),
        ("2000-02-29T12:34:56Z", 951_827_696.0),
        ("1969-12-31T23:59:59Z", -1.0),
        ("2026-10-11T17:00:00.123456Z", 1_791_738_000.123),
        ("2026-10-11T19:00:00+02:00", 1_791_738_000.0),
        ("2026-10-11T12:30:00-04:30", 1_791_738_000.0),
        ("2026-10-11t17:00:00z", 1_791_738_000.0),
    ])
    func parsesSTSExpirations(string: String, seconds: Double) throws {
        let date = try #require(parseRFC3339(string))
        #expect(abs(date.timeIntervalSince1970 - seconds) < 0.0005)
    }

    @Test(arguments: ["", "2026-10-11", "2026-10-11T17:00:00", "2026-13-11T17:00:00Z", "2026-10-11T24:00:00Z",
        "2026-10-11T17:00:00.Z", "2026-10-11T17:00:00+0200", "2026-10-11T17:00:00Zjunk", "x026-10-11T17:00:00Z"])
    func rejectsInvalidSTSExpirations(string: String) {
        #expect(parseRFC3339(string) == nil)
    }
}

@Suite struct AWSCredentialsProviderTests {
    func makeProvider(
        _ transport: MockHTTPTransport,
        clock: TestClock = TestClock(),
        sessionName: String? = nil,
        environment: [String: String] = ["VERCEL_OIDC_TOKEN": "t"],
        refreshWindow: Duration = .seconds(300)
    ) -> AWSCredentialsProvider {
        AWSCredentialsProvider(
            roleARN: roleARN, region: "us-east-1", sessionName: sessionName, durationSeconds: nil,
            audience: nil, jti: nil, refreshWindow: refreshWindow,
            client: makeClient(transport, environment: environment, clock: clock)
        )
    }

    @Test func cachesUntilTheRefreshWindow() async throws {
        let transport = MockHTTPTransport(responses: [stsResponse(accessKeyID: "first"), stsResponse(accessKeyID: "second", expiration: "2026-10-11T18:00:00Z")])
        let clock = TestClock()
        let provider = makeProvider(transport, clock: clock)

        #expect(try await provider.credentials().accessKeyID == "first")
        clock.advance(by: 3600 - 301) // 5 minutes and 1 second before expiration.
        #expect(try await provider.credentials().accessKeyID == "first")
        #expect(transport.requests.count == 1)

        clock.advance(by: 1) // Within the refresh window.
        #expect(try await provider.credentials().accessKeyID == "second")
        #expect(try await provider.credentials().accessKeyID == "second")
        #expect(transport.requests.count == 2)
    }

    @Test func forceRefreshAndInvalidate() async throws {
        let transport = MockHTTPTransport(responses: [stsResponse(accessKeyID: "1"), stsResponse(accessKeyID: "2"), stsResponse(accessKeyID: "3")])
        let provider = makeProvider(transport)
        #expect(try await provider.credentials().accessKeyID == "1")
        #expect(try await provider.credentials(forceRefresh: true).accessKeyID == "2")
        await provider.invalidate()
        #expect(try await provider.credentials().accessKeyID == "3")
        #expect(transport.requests.count == 3)
    }

    @Test func concurrentCallersShareOneRequest() async throws {
        let transport = MockHTTPTransport { _ in
            try await Task.sleep(for: .milliseconds(50))
            return stsResponse()
        }
        let provider = makeProvider(transport)
        let keys = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask { try await provider.credentials().accessKeyID }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(keys == Array(repeating: "ASIAEXAMPLE", count: 10))
        #expect(transport.requests.count == 1)
    }

    @Test func failuresAreNotCached() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(status: .forbidden, body: "<ErrorResponse><Error><Code>AccessDenied</Code><Message>Not authorized</Message></Error></ErrorResponse>"),
            stsResponse(),
        ])
        let provider = makeProvider(transport)
        await #expect(throws: VercelOIDCError.awsSTS(statusCode: 403, code: "AccessDenied", message: "Not authorized")) {
            try await provider.credentials()
        }
        #expect(try await provider.credentials().accessKeyID == "ASIAEXAMPLE")
        #expect(transport.requests.count == 2)
    }

    @Test func keepsOneSessionNameAndReadsTheTokenOnEachRefresh() async throws {
        let transport = MockHTTPTransport(responses: [stsResponse(), stsResponse()])
        let provider = makeProvider(transport, environment: [:])
        _ = try await Vercel.withRequest(HTTPFields([("x-vercel-oidc-token", "request-1")])) {
            try await provider.credentials()
        }
        _ = try await provider.credentials(headers: HTTPFields([("x-vercel-oidc-token", "request-2")]), forceRefresh: true)

        let first = Dictionary(uniqueKeysWithValues: formFields(transport.requests[0].text))
        let second = Dictionary(uniqueKeysWithValues: formFields(transport.requests[1].text))
        #expect(first["WebIdentityToken"] == "request-1")
        #expect(second["WebIdentityToken"] == "request-2")
        #expect(first["RoleSessionName"] == provider.sessionName)
        #expect(second["RoleSessionName"] == provider.sessionName)
        #expect(provider.sessionName.hasPrefix("vercel-"))
        #expect(makeProvider(transport, sessionName: "fixed").sessionName == "fixed")
    }

    /// A refresh window as long as the credentials' lifetime (or longer) would refresh on every
    /// call; the credentials are used for half their lifetime instead.
    @Test(arguments: [Duration.seconds(3600), .seconds(7200)])
    func refreshWindowAtLeastTheLifetimeCachesForHalfTheLifetime(window: Duration) async throws {
        let transport = MockHTTPTransport(responses: [stsResponse(accessKeyID: "first"), stsResponse(accessKeyID: "second", expiration: "2026-10-11T18:00:00Z")])
        let clock = TestClock()
        let provider = makeProvider(transport, clock: clock, refreshWindow: window)
        #expect(provider.refreshWindow == window)

        #expect(try await provider.credentials().accessKeyID == "first")
        clock.advance(by: 1799)
        #expect(try await provider.credentials().accessKeyID == "first")
        #expect(transport.requests.count == 1)
        clock.advance(by: 1)
        #expect(try await provider.credentials().accessKeyID == "second")
        #expect(transport.requests.count == 2)
    }

    @Test func negativeRefreshWindowCountsAsZero() async throws {
        let transport = MockHTTPTransport(responses: [stsResponse(accessKeyID: "first"), stsResponse(accessKeyID: "second")])
        let clock = TestClock()
        let provider = makeProvider(transport, clock: clock, refreshWindow: .seconds(-60))
        #expect(provider.refreshWindow == .zero)
        #expect(try await provider.credentials().accessKeyID == "first")
        clock.advance(by: 3599)
        #expect(try await provider.credentials().accessKeyID == "first")
        clock.advance(by: 1)
        #expect(try await provider.credentials().accessKeyID == "second")
    }

    @Test func refreshDates() {
        let credentials = AWSCredentials(accessKeyID: "a", secretAccessKey: "s", sessionToken: "t", expiration: testNow.addingTimeInterval(900))
        func refresh(_ window: Duration, obtainedAt: Date = testNow) -> TimeInterval {
            AWSCredentialsProvider.refreshDate(for: credentials, obtainedAt: obtainedAt, refreshWindow: window).timeIntervalSince(testNow)
        }
        #expect(refresh(.seconds(300)) == 600)
        #expect(refresh(.zero) == 900)
        #expect(refresh(.seconds(899)) == 1)
        #expect(refresh(.seconds(900)) == 450)
        #expect(refresh(.seconds(3600)) == 450)
        // Already expired when obtained: never used.
        #expect(refresh(.seconds(300), obtainedAt: testNow.addingTimeInterval(1000)) == 900)
    }

    @Test func printingAProviderShowsNoCredentials() async throws {
        let transport = MockHTTPTransport(responses: [stsResponse()])
        let provider = makeProvider(transport)
        _ = try await provider.credentials()
        var dumped = ""
        dump(provider, to: &dumped)
        for output in [String(describing: provider), String(reflecting: provider), "\(provider)", dumped] {
            #expect(output.contains(roleARN), "\(output)")
            #expect(!output.contains("ASIAEXAMPLE"), "\(output)")
            #expect(!output.contains("secret"), "\(output)")
        }
    }
}

@Suite struct OIDCRedactionTests {
    func outputs(_ value: Any) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), "\(value)", dumped]
    }

    @Test func credentialsHideTheirSecrets() {
        let credentials = AWSCredentials(
            accessKeyID: "ASIAEXAMPLE", secretAccessKey: "secret-key", sessionToken: "session-token",
            expiration: testNow, assumedRoleARN: "arn:aws:sts::1:assumed-role/r/s"
        )
        for output in outputs(credentials) + outputs([credentials]) + outputs(Optional(credentials) as Any) {
            #expect(output.contains("ASIAEXAMPLE"), "\(output)")
            #expect(!output.contains("secret-key"), "\(output)")
            #expect(!output.contains("session-token"), "\(output)")
        }
    }

    @Test func tokensHideTheEncodedToken() throws {
        let raw = makeJWT(#"{"iss":"https://oidc.vercel.com/acme","sub":"owner:acme","exp":1791738000}"#)
        let token = try VercelOIDCToken(raw)
        for output in outputs(token) {
            #expect(output.contains("https://oidc.vercel.com/acme"), "\(output)")
            #expect(!output.contains(raw), "\(output)")
            #expect(!output.contains("c2lnbmF0dXJl"), "\(output)")
        }
        #expect(token.rawValue == raw)
    }
}
