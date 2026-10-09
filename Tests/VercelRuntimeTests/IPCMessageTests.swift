import Testing
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
