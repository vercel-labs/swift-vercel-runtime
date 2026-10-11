import HTTPTypes
import Logging
import Testing
@testable import VercelProtocol
@testable import VercelRuntime

@Suite struct RequestInfoTests {
    func fields(_ pairs: [(String, String)]) -> HTTPFields {
        var fields = HTTPFields()
        for (name, value) in pairs {
            fields.append(HTTPField(name: HTTPField.Name(name)!, value: value))
        }
        return fields
    }

    @Test func geolocationFromVercelHeaders() {
        let info = fields([
            ("x-vercel-ip-city", "S%C3%A3o%20Paulo"),
            ("x-vercel-ip-country", "BR"),
            ("x-vercel-ip-country-region", "SP"),
            ("x-vercel-ip-latitude", "-23.5"),
            ("x-vercel-ip-longitude", "-46.6"),
            ("x-vercel-ip-postal-code", "01000"),
            ("x-vercel-id", "gru1::iad1::abc-123"),
            ("x-real-ip", "203.0.113.7"),
        ]).vercel

        #expect(info.geolocation == VercelGeolocation(
            city: "São Paulo",
            country: "BR",
            flag: "🇧🇷",
            countryRegion: "SP",
            region: "gru1",
            latitude: "-23.5",
            longitude: "-46.6",
            postalCode: "01000"
        ))
        #expect(info.ipAddress == "203.0.113.7")
        #expect(info.id == "gru1::iad1::abc-123")
    }

    @Test func geolocationDefaultsLocally() {
        let geolocation = HTTPFields().vercel.geolocation
        #expect(geolocation == VercelGeolocation(region: "dev1"))
    }

    @Test(arguments: [("US", "🇺🇸"), ("us", nil), ("USA", nil), ("", nil)] as [(String, String?)])
    func flags(code: String, flag: String?) {
        #expect(flagEmoji(code) == flag)
    }

    @Test func percentDecoding() {
        #expect(percentDecoded("San%20Francisco") == "San Francisco")
        #expect(percentDecoded("Z%C3%BCrich") == "Zürich")
        #expect(percentDecoded("plain") == "plain")
        #expect(percentDecoded("bad%2") == "bad%2")
        #expect(percentDecoded("bad%ZZ") == "bad%ZZ")
        #expect(percentDecoded("%FF") == "%FF")
    }

    @Test func oidcTokenPrefersTheRequestHeader() {
        #expect(fields([("x-vercel-oidc-token", "from-request")]).vercel.oidcToken == "from-request")
    }
}

@Suite struct EnvironmentTests {
    @Test func readsSystemVariables() {
        let environment = VercelEnvironment(values: [
            "VERCEL": "1",
            "VERCEL_ENV": "preview",
            "VERCEL_URL": "app-abc.vercel.app",
            "VERCEL_REGION": "iad1",
            "VERCEL_GIT_COMMIT_SHA": "deadbeef",
            "VERCEL_GIT_COMMIT_REF": "",
            "CRON_SECRET": "s3cret",
        ])
        #expect(environment.isVercel)
        #expect(environment.target == .preview)
        #expect(environment.url == "app-abc.vercel.app")
        #expect(environment.region == "iad1")
        #expect(environment.git.commitSHA == "deadbeef")
        #expect(environment.git.commitRef == nil, "empty values are unset")
        #expect(environment.cronSecret == "s3cret")
        #expect(environment.branchURL == nil)
    }

    @Test func emptyEnvironment() {
        let environment = VercelEnvironment(values: [:])
        #expect(!environment.isVercel)
        #expect(environment.target == nil)
    }
}

@Suite struct CronTests {
    func headers(authorization: String?) -> HTTPFields {
        var fields = HTTPFields()
        if let authorization {
            fields[.authorization] = authorization
        }
        return fields
    }

    @Test func requiresBearerSecretWhenConfigured() {
        #expect(VercelCron.isAuthorized(headers(authorization: "Bearer s3cret"), secret: "s3cret"))
        #expect(!VercelCron.isAuthorized(headers(authorization: "Bearer wrong"), secret: "s3cret"))
        #expect(!VercelCron.isAuthorized(headers(authorization: "s3cret"), secret: "s3cret"))
        #expect(!VercelCron.isAuthorized(headers(authorization: nil), secret: "s3cret"))
    }

    @Test func allowsEverythingWithoutSecret() {
        #expect(VercelCron.isAuthorized(headers(authorization: nil), secret: nil))
        #expect(VercelCron.isAuthorized(headers(authorization: nil), secret: ""))
    }

    @Test func constantTimeComparison() {
        #expect(constantTimeEquals("abc", "abc"))
        #expect(!constantTimeEquals("abc", "abd"))
        #expect(!constantTimeEquals("abc", "abcd"))
        #expect(!constantTimeEquals("", "a"))
    }
}

@Suite struct LogHandlerTests {
    @Test func levelMapping() {
        #expect(IPCMessage.LogLevel(Logger.Level.trace) == .trace)
        #expect(IPCMessage.LogLevel(Logger.Level.notice) == .info)
        #expect(IPCMessage.LogLevel(Logger.Level.warning) == .warn)
        #expect(IPCMessage.LogLevel(Logger.Level.critical) == .fatal)
    }

    @Test func rendersSortedMetadata() {
        #expect(VercelLogHandler.render(message: "hi", metadata: [:]) == "hi")
        #expect(VercelLogHandler.render(message: "hi", metadata: ["b": "2", "a": "1"]) == "hi a=1 b=2")
    }
}

@Suite struct RuntimeMessageTests {
    @Test func decodesApproachingTimeout() {
        let frame = Array(#"{"type":"approaching-timeout","context":{"invocationId":"inv","requestId":3}}"#.utf8)
        #expect(RuntimeMessage(frame: frame) == .approachingTimeout(InvocationContext(invocationID: "inv", requestID: 3)))
    }

    @Test func toleratesUnknownAndMalformedMessages() {
        #expect(RuntimeMessage(frame: Array(#"{"type":"something-new","payload":{}}"#.utf8)) == .unknown(type: "something-new"))
        #expect(RuntimeMessage(frame: Array("not json".utf8)) == nil)
    }
}
