import Testing
@testable import VercelProtocol
@testable import VercelRuntime

@Suite struct IPCMessageTests {
    @Test func serverStarted() {
        let message = IPCMessage.serverStarted(initDuration: 150, httpPort: 3000)
        #expect(message.json == #"{"type":"server-started","payload":{"initDuration":150,"httpPort":3000}}"#)
    }

    @Test func endWithNullError() {
        let context = InvocationContext(invocationID: "abc123", requestID: 42)
        #expect(
            IPCMessage.end(context).json
                == #"{"type":"end","payload":{"context":{"invocationId":"abc123","requestId":42},"error":null}}"#
        )
    }

    @Test func endWithoutRequestID() {
        let context = InvocationContext(invocationID: "abc", requestID: nil)
        #expect(
            IPCMessage.end(context, error: "boom").json
                == #"{"type":"end","payload":{"context":{"invocationId":"abc","requestId":null},"error":"boom"}}"#
        )
    }

    @Test func logIsBase64Encoded() {
        let context = InvocationContext(invocationID: "abc123", requestID: 42)
        #expect(
            IPCMessage.log(context, message: "Hello", level: .info).json
                == #"{"type":"log","payload":{"context":{"invocationId":"abc123","requestId":42},"message":"SGVsbG8=","level":"info"}}"#
        )
    }

    @Test func unrecoverableErrorEscapesMessage() {
        let message = IPCMessage.unrecoverableError(exitCode: 1, message: "bad \"thing\"\n\tat\u{01}")
        #expect(
            message.json
                == #"{"type":"unrecoverable-error","payload":{"exitCode":1,"message":"bad \"thing\"\n\tat\u0001"}}"#
        )
    }

    @Test func fetchMetricMatchesTheRuntimeSchema() {
        let context = InvocationContext(invocationID: "inv", requestID: 1)
        let metric = FetchMetric(id: 1, method: "GET", host: "example.com", pathname: "/v1/x", search: "a=1", statusCode: 200, start: 1_791_734_674_495, duration: 45)
        let message = IPCMessage.fetchMetric(context, metric)
        #expect(
            message.json
                == #"{"type":"metric","payload":{"context":{"invocationId":"inv","requestId":1},"type":"fetch-metric","payload":{"pathname":"/v1/x","search":"a=1","start":1791734674495,"duration":45,"host":"example.com","statusCode":200,"method":"GET","id":1}}}"#
        )
        #expect(
            IPCMessage.fetchMetric(InvocationContext(invocationID: "inv", requestID: nil), metric).json
                .hasPrefix(#"{"type":"metric","payload":{"context":{"invocationId":"inv","requestId":null},"type":"fetch-metric""#)
        )
    }

    @Test func onlyLogsAndMetricsAreDroppable() {
        let context = InvocationContext(invocationID: "inv", requestID: 1)
        let metric = FetchMetric(id: 1, method: "GET", host: "h", pathname: "/", search: "", statusCode: 200, start: 0, duration: 0)
        #expect(IPCMessage.log(context, message: "m", level: .info).isDroppable)
        #expect(IPCMessage.fetchMetric(context, metric).isDroppable)
        #expect(!IPCMessage.end(context).isDroppable)
        #expect(!IPCMessage.serverStarted(initDuration: 0, httpPort: 1).isDroppable)
        #expect(!IPCMessage.unrecoverableError(exitCode: 1, message: "m").isDroppable)
    }

    @Test func jsonObjectsAreSortedAndEscaped() {
        #expect(JSON.object([:]) == "{}")
        #expect(JSON.object(["b": "2", "a": "\"1\""]) == #"{"a":"\"1\"","b":"2"}"#)
    }

    @Test func frameIsNulTerminated() {
        let frame = IPCMessage.serverStarted(initDuration: 0, httpPort: 1).frame
        #expect(frame.last == 0)
        #expect(frame.dropLast().contains(0) == false)
    }

    @Test(arguments: [
        ("", ""), ("f", "Zg=="), ("fo", "Zm8="), ("foo", "Zm9v"), ("foob", "Zm9vYg=="),
        ("fooba", "Zm9vYmE="), ("foobar", "Zm9vYmFy"), ("héllo ✓", "aMOpbGxvIOKckw=="),
    ])
    func base64(input: String, expected: String) {
        #expect(Base64.encode(Array(input.utf8)) == expected)
    }

    @Test func requestContextFromHeaders() {
        #expect(InvocationContext(invocationID: "inv", requestID: "7") == InvocationContext(invocationID: "inv", requestID: 7))
        #expect(InvocationContext(invocationID: "inv", requestID: " 7 ")?.requestID == 7)
        #expect(InvocationContext(invocationID: "inv", requestID: "-1")?.requestID == nil)
        #expect(InvocationContext(invocationID: "inv", requestID: "4294967296")?.requestID == nil)
        #expect(InvocationContext(invocationID: "inv", requestID: nil)?.requestID == nil)
        #expect(InvocationContext(invocationID: nil, requestID: "1") == nil)
        #expect(InvocationContext(invocationID: "", requestID: "1") == nil)
    }

    @Test func internalHeaderNames() {
        #expect(VercelHeader.isInternal("x-vercel-internal-invocation-id"))
        #expect(VercelHeader.isInternal("x-vercel-internal-trace-id"))
        #expect(!VercelHeader.isInternal("x-vercel-id"))
        #expect(!VercelHeader.isInternal("x-vercel-oidc-token"))
    }
}
