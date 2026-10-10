import Synchronization
import VercelRuntime

/// The app's side of the bootstrap socket, as seen by the tracker.
package protocol AppPeer: AnyObject, Sendable {
    func send(_ message: BootstrapMessage)
}

/// Tracks the requests the bootstrap is proxying and decides when each one ends.
///
/// The runtime's `end` for a request is sent once its response has been fully proxied and, if the
/// app is connected to the bootstrap socket, once the app has released it (its `waitUntil` work is
/// done). Every request ends exactly once.
package final class RequestTracker: Sendable {
    private struct Entry {
        var context: InvocationContext
        var responseFinished = false
    }

    private struct State {
        var nextToken: UInt64 = 0
        var entries: [String: Entry] = [:]
        var tokens: [InvocationContext: String] = [:]
        var app: (any AppPeer)?
    }

    private let state = Mutex(State())
    private let sendToRuntime: @Sendable (IPCMessage) -> Void

    package init(sendToRuntime: @escaping @Sendable (IPCMessage) -> Void) {
        self.sendToRuntime = sendToRuntime
    }

    /// Starts tracking a request from the runtime. Returns the token the app sees for it.
    package func begin(_ context: InvocationContext) -> String {
        state.withLock { state in
            state.nextToken += 1
            let token = String(state.nextToken)
            state.entries[token] = Entry(context: context)
            state.tokens[context] = token
            return token
        }
    }

    /// The response has been fully proxied, or the connection carrying it is gone.
    package func responseFinished(token: String) {
        enum Action {
            case none
            case end(InvocationContext)
            case askApp(any AppPeer)
        }
        let action = state.withLock { state -> Action in
            guard var entry = state.entries[token], !entry.responseFinished else { return .none }
            if let app = state.app {
                entry.responseFinished = true
                state.entries[token] = entry
                return .askApp(app)
            }
            Self.remove(token, context: entry.context, from: &state)
            return .end(entry.context)
        }
        switch action {
        case .none: break
        case .end(let context): sendToRuntime(.end(context))
        case .askApp(let app): app.send(.responseFinished(token: token))
        }
    }

    /// The app has no more work for a finished request.
    package func released(token: String) {
        let context = state.withLock { state -> InvocationContext? in
            guard let entry = state.entries[token], entry.responseFinished else { return nil }
            Self.remove(token, context: entry.context, from: &state)
            return entry.context
        }
        if let context {
            sendToRuntime(.end(context))
        }
    }

    /// A log line from the app. Written to standard output if the request already ended.
    package func log(token: String, message: String, level: IPCMessage.LogLevel) {
        if let context = state.withLock({ $0.entries[token]?.context }) {
            sendToRuntime(.log(context, message: message, level: level))
        } else {
            writeLine("\(level.rawValue): \(message)", to: level == .error || level == .fatal ? 2 : 1)
        }
    }

    /// The runtime is about to time the request out; tell the app to cancel its background work.
    package func approachingTimeout(_ context: InvocationContext) {
        let target = state.withLock { state -> (String, any AppPeer)? in
            guard let token = state.tokens[context], let app = state.app else { return nil }
            return (token, app)
        }
        if let (token, app) = target {
            app.send(.approachingTimeout(token: token))
        }
    }

    /// Registers the app's connection. Only one is accepted.
    package func appConnected(_ app: any AppPeer) -> Bool {
        state.withLock { state in
            guard state.app == nil else { return false }
            state.app = app
            return true
        }
    }

    /// The app's connection closed: every request waiting for it ends now.
    package func appDisconnected(_ app: any AppPeer) {
        let ended = state.withLock { state -> [InvocationContext] in
            guard state.app === app else { return [] }
            state.app = nil
            let waiting = state.entries.filter { $0.value.responseFinished }
            for (token, entry) in waiting {
                Self.remove(token, context: entry.context, from: &state)
            }
            return waiting.map(\.value.context)
        }
        for context in ended {
            sendToRuntime(.end(context))
        }
    }

    /// Requests that have not ended yet.
    package var activeCount: Int {
        state.withLock { $0.entries.count }
    }

    private static func remove(_ token: String, context: InvocationContext, from state: inout State) {
        state.entries[token] = nil
        if state.tokens[context] == token {
            state.tokens[context] = nil
        }
    }
}
