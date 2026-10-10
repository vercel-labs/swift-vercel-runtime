import HTTPTypes
import NIOHTTP1
import Synchronization
import Testing
@testable import VercelBootstrapCore
@testable import VercelRuntime

/// Records what the tracker sends to the runtime and to the app.
final class Recorder: AppPeer, @unchecked Sendable {
    private let lock = Mutex<([IPCMessage], [BootstrapMessage])>(([], []))

    func send(_ message: BootstrapMessage) {
        lock.withLock { $0.1.append(message) }
    }

    func runtime(_ message: IPCMessage) {
        lock.withLock { $0.0.append(message) }
    }

    var toRuntime: [IPCMessage] { lock.withLock { $0.0 } }
    var toApp: [BootstrapMessage] { lock.withLock { $0.1 } }
}

@Suite struct RequestTrackerTests {
    let context = InvocationContext(invocationID: "inv", requestID: 1)

    @Test func endsWhenTheResponseFinishesWithoutAnApp() {
        let recorder = Recorder()
        let tracker = RequestTracker { recorder.runtime($0) }
        let token = tracker.begin(context)
        #expect(recorder.toRuntime.isEmpty)
        tracker.responseFinished(token: token)
        tracker.responseFinished(token: token)
        #expect(recorder.toRuntime == [.end(context)])
        #expect(tracker.activeCount == 0)
    }

    @Test func waitsForTheAppToRelease() {
        let recorder = Recorder()
        let tracker = RequestTracker { recorder.runtime($0) }
        #expect(tracker.appConnected(recorder))
        #expect(!tracker.appConnected(Recorder()), "only one app connection")

        let token = tracker.begin(context)
        tracker.log(token: token, message: "hello", level: .warn)
        tracker.released(token: token)  // ignored: the response is still going
        tracker.responseFinished(token: token)
        #expect(recorder.toApp == [.responseFinished(token: token)])
        #expect(recorder.toRuntime == [.log(context, message: "hello", level: .warn)])

        tracker.released(token: token)
        tracker.released(token: token)
        #expect(recorder.toRuntime == [.log(context, message: "hello", level: .warn), .end(context)])
    }

    @Test func appDisconnectingEndsWaitingRequests() {
        let recorder = Recorder()
        let tracker = RequestTracker { recorder.runtime($0) }
        _ = tracker.appConnected(recorder)
        let waiting = tracker.begin(context)
        let running = tracker.begin(InvocationContext(invocationID: "inv", requestID: 2))
        tracker.responseFinished(token: waiting)
        tracker.appDisconnected(recorder)
        #expect(recorder.toRuntime == [.end(context)])

        // Without the app, the other request ends with its response.
        tracker.responseFinished(token: running)
        #expect(recorder.toRuntime.count == 2)
    }

    @Test func forwardsApproachingTimeoutToTheApp() {
        let recorder = Recorder()
        let tracker = RequestTracker { recorder.runtime($0) }
        _ = tracker.appConnected(recorder)
        let token = tracker.begin(context)
        tracker.approachingTimeout(context)
        tracker.approachingTimeout(InvocationContext(invocationID: "other", requestID: nil))
        #expect(recorder.toApp == [.approachingTimeout(token: token)])
    }

    @Test func tokensAreUnique() {
        let tracker = RequestTracker { _ in }
        let tokens = (0..<100).map { _ in tracker.begin(context) }
        #expect(Set(tokens).count == 100)
    }
}

@Suite struct PortDiscoveryTests {
    // Trimmed real output. 0100007F:1F90 is 127.0.0.1:8080, 00000000:0BB8 is 0.0.0.0:3000.
    let tcp = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1111 1 0000000000000000 100 0 0 10 0
           1: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 2222 1 0000000000000000 100 0 0 10 0
           2: 0100007F:1F90 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000        0 3333 1 0000000000000000 20 4 30 10 -1
           3: 0100007F:2328 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 4444 1 0000000000000000 100 0 0 10 0
        """
    // [::]:8443 and [::1]:9000
    let tcp6 = """
          sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000000000000000000000000000:20FB 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 5555 1 0000000000000000 100 0 0 10 0
           1: 00000000000000000000000001000000:2328 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 6666 1 0000000000000000 100 0 0 10 0
        """

    @Test func parsesListeningSocketsOwnedByTheProcess() {
        let ipv4 = PortDiscovery.parseTCPTable(tcp, ipv6: false, inodes: [1111, 2222, 3333])
        #expect(ipv4 == [.init(host: "127.0.0.1", port: 8080), .init(host: "127.0.0.1", port: 3000)])
        let ipv6 = PortDiscovery.parseTCPTable(tcp6, ipv6: true, inodes: [5555, 6666])
        #expect(ipv6 == [.init(host: "::1", port: 8443), .init(host: "0:0:0:0:0:0:0:1", port: 9000)])
        #expect(PortDiscovery.parseTCPTable(tcp, ipv6: false, inodes: []).isEmpty)
    }

    @Test func prefersPortThenOnlyThenCommonThenLowest() {
        let listeners: [PortDiscovery.Listener] = [.init(host: "127.0.0.1", port: 9000), .init(host: "127.0.0.1", port: 8080)]
        #expect(PortDiscovery.choose(listeners, preferredPort: 9000)?.port == 9000)
        #expect(PortDiscovery.choose(listeners, preferredPort: 1234)?.port == 8080)
        #expect(PortDiscovery.choose([.init(host: "127.0.0.1", port: 4567)], preferredPort: 1234)?.port == 4567)
        #expect(PortDiscovery.choose([.init(host: "::1", port: 9001), .init(host: "::1", port: 9002)], preferredPort: 1)?.port == 9001)
        #expect(PortDiscovery.choose([], preferredPort: 1) == nil)
        // The same port on IPv4 and IPv6: IPv4.
        #expect(PortDiscovery.choose([.init(host: "::1", port: 5000), .init(host: "127.0.0.1", port: 5000)], preferredPort: 5000)?.host == "127.0.0.1")
    }
}

@Suite struct BootstrapConfigurationTests {
    @Test func parsesTheFileWrittenByThePlugin() throws {
        let configuration = try BootstrapConfiguration(json: Array(#"{"executable":"App","crons":["/cron/","/jobs?x=1"]}"#.utf8))
        #expect(configuration.executable == "App")
        #expect(configuration.cronPaths == ["/cron", "/jobs"])
        #expect(configuration.isCronPath("/cron"))
        #expect(configuration.isCronPath("/cron/?secret=1"))
        #expect(configuration.isCronPath("/jobs"))
        #expect(!configuration.isCronPath("/cron/other"))
        #expect(!configuration.isCronPath("/"))
    }

    @Test func rejectsPathsAsExecutable() {
        #expect(throws: BootstrapError.self) {
            try BootstrapConfiguration(json: Array(#"{"executable":"../App"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try BootstrapConfiguration(json: Array(#"{"crons":[]}"#.utf8))
        }
    }

    @Test func normalizesPaths() {
        #expect(normalizedPath("/") == "/")
        #expect(normalizedPath("") == "/")
        #expect(normalizedPath("/a//") == "/a")
        #expect(normalizedPath("/a?b=/c") == "/a")
        #expect(normalizedPath("/_vercel/ping") == "/_vercel/ping")
    }
}

@Suite struct HeaderRewriteTests {
    @Test func stripsInternalHeadersAndClientTokens() {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "example.com")
        headers.add(name: "X-Vercel-Internal-Invocation-Id", value: "inv")
        headers.add(name: "x-vercel-internal-request-id", value: "3")
        headers.add(name: "x-vercel-internal-oidc-token", value: "token")
        headers.add(name: "x-vercel-bootstrap-request", value: "spoofed")
        headers.add(name: "Accept", value: "a")
        headers.add(name: "Accept", value: "b")

        let (fields, invocation) = rewriteRequestHeaders(headers)
        #expect(invocation == InvocationContext(invocationID: "inv", requestID: 3))
        let forwarded = HTTPHeaders(fields)
        #expect(forwarded.map(\.name) == ["Host", "Accept", "Accept", "x-vercel-oidc-token"])
        #expect(forwarded["accept"] == ["a", "b"])
        #expect(forwarded["x-vercel-oidc-token"] == ["token"])
    }

    @Test func requestsFromOutsideTheRuntimeHaveNoInvocation() {
        var headers = HTTPHeaders()
        headers.add(name: "x-vercel-bootstrap-request", value: "spoofed")
        let (fields, invocation) = rewriteRequestHeaders(headers)
        #expect(invocation == nil)
        #expect(fields.isEmpty)
    }
}
