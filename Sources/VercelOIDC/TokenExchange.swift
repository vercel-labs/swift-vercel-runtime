#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import Synchronization
import VercelHTTP

/// The Vercel token exchange endpoint.
let tokenExchangeURL = "https://oidc.vercel.com/~token"

extension OIDCClient {
    /// Exchanges `token` at ``tokenExchangeURL``, like `exchangeVercelOidcToken` from `@vercel/oidc`.
    ///
    /// Exchanged tokens are cached until they expire, keyed by a hash of `token`, `audience` and
    /// `jti`. `skipCache` forces an exchange; its result still replaces the cached entry.
    /// Concurrent calls with the same key, with or without `skipCache`, share one request.
    func exchange(token: String, audience: String?, jti: String?, skipCache: Bool, headers: HTTPFields? = nil) async throws -> String {
        let key = exchangeCacheKey(token: token, audience: audience, jti: jti)
        if !skipCache, let cached = exchangeCache.get(key, now: now()) {
            return cached
        }
        return try await exchangeCache.sharing(key) {
            try await self.requestExchange(token: token, audience: audience, jti: jti, key: key, headers: headers)
        }
    }

    /// Sends the exchange request and caches the result under `key`.
    private func requestExchange(token: String, audience: String?, jti: String?, key: String, headers: HTTPFields?) async throws -> String {
        let body = ExchangeRequestBody(token: token, aud: audience, jti: jti?.isEmpty == false ? jti : nil)
        let response = try await send(
            .post,
            tokenExchangeURL,
            headerFields: [
                .contentType: "application/json",
                .accept: "application/json",
                .userAgent: userAgent,
            ],
            body: Array(try JSONEncoder().encode(body)),
            requestHeaders: headers
        )
        guard (200..<300).contains(response.status.code) else {
            throw VercelOIDCError.exchangeFailed(statusCode: response.status.code, message: exchangeErrorMessage(response))
        }

        let decoded: ExchangeResponseBody
        do {
            decoded = try response.decode(ExchangeResponseBody.self)
        } catch DecodingError.dataCorrupted {
            throw VercelOIDCError.invalidExchangeResponse(reason: "response was not valid JSON")
        } catch {
            throw VercelOIDCError.invalidExchangeResponse(reason: "response did not contain a token")
        }
        guard let exchanged = decoded.token else {
            throw VercelOIDCError.invalidExchangeResponse(reason: "response did not contain a token")
        }

        // `expiry` is the exchanged token's `exp` claim in Unix seconds; read the claim when it is
        // missing. Cache only tokens that expire in the future.
        let expiresAt = decoded.expiry.map { Date(timeIntervalSince1970: $0) }
            ?? (try? VercelOIDCToken(exchanged))?.expiresAt
        if let expiresAt, expiresAt > now() {
            exchangeCache.set(key, token: exchanged, expiresAt: expiresAt)
        }
        return exchanged
    }
}

/// SHA-256 of the JSON array `[token, audience, jti]` (`null` for `nil`), like `@vercel/oidc`, so the
/// raw token is never kept as a key.
func exchangeCacheKey(token: String, audience: String?, jti: String?) -> String {
    let input = (try? JSONEncoder().encode([token, audience, jti])).map(Array.init) ?? Array(token.utf8)
    return SHA256.hexDigest(input)
}

/// The endpoint's `{"error": "..."}` message, else the status.
private func exchangeErrorMessage(_ response: VercelHTTPResponse) -> String {
    struct ErrorBody: Decodable { var error: String }
    if let body = try? response.decode(ErrorBody.self) {
        return body.error
    }
    let reason = response.status.reasonPhrase
    return reason.isEmpty ? "HTTP \(response.status.code)" : reason
}

private struct ExchangeRequestBody: Encodable {
    var token: String
    var aud: String?
    var jti: String?
}

/// `{"token": "...", "expiry": <Unix seconds>}`. Fields with another type count as missing.
private struct ExchangeResponseBody: Decodable {
    var token: String?
    var expiry: Double?

    private enum CodingKeys: String, CodingKey { case token, expiry }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try? container.decodeIfPresent(String.self, forKey: .token)
        expiry = try? container.decodeIfPresent(Double.self, forKey: .expiry)
    }
}

/// A bounded, expiry-aware cache of exchanged tokens. Expired entries are dropped when read; past
/// `maxEntries`, the least recently used entry is evicted.
final class ExchangeCache: Sendable {
    /// The process-wide cache used by ``OIDC``.
    static let shared = ExchangeCache()

    private struct Entry {
        var token: String
        var expiresAt: Date
        var lastUsed: UInt64
    }

    private struct State {
        var entries: [String: Entry] = [:]
        /// Exchanges in flight, by key, with the tick that identifies them.
        var inFlight: [String: (id: UInt64, task: Task<String, any Error>)] = [:]
        var tick: UInt64 = 0

        mutating func nextTick() -> UInt64 {
            tick += 1
            return tick
        }
    }

    let maxEntries: Int
    private let state = Mutex(State())

    init(maxEntries: Int = 1000) {
        self.maxEntries = maxEntries
    }

    /// The number of entries, including expired ones not read since they expired.
    var count: Int {
        state.withLock { $0.entries.count }
    }

    /// The token cached for `key` if it has not expired at `now`, marking it most recently used.
    func get(_ key: String, now: Date) -> String? {
        state.withLock { state in
            guard let entry = state.entries[key] else { return nil }
            guard entry.expiresAt > now else {
                state.entries[key] = nil
                return nil
            }
            let tick = state.nextTick()
            state.entries[key]?.lastUsed = tick
            return entry.token
        }
    }

    /// The result of the exchange in flight for `key`, or of `operation`, started now and shared
    /// with every caller asking for `key` until it finishes.
    func sharing(_ key: String, _ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        let task = state.withLock { state -> Task<String, any Error> in
            if let running = state.inFlight[key] {
                return running.task
            }
            let id = state.nextTick()
            let task = Task {
                defer { self.finished(key, id: id) }
                return try await operation()
            }
            state.inFlight[key] = (id, task)
            return task
        }
        return try await task.value
    }

    /// The number of exchanges in flight.
    var inFlightCount: Int {
        state.withLock { $0.inFlight.count }
    }

    private func finished(_ key: String, id: UInt64) {
        state.withLock { state in
            if state.inFlight[key]?.id == id {
                state.inFlight[key] = nil
            }
        }
    }

    /// Caches `token` for `key` until `expiresAt`, evicting the least recently used entries beyond
    /// ``maxEntries``.
    func set(_ key: String, token: String, expiresAt: Date) {
        state.withLock { state in
            let tick = state.nextTick()
            state.entries[key] = Entry(token: token, expiresAt: expiresAt, lastUsed: tick)
            while state.entries.count > maxEntries,
                let oldest = state.entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key
            {
                state.entries[oldest] = nil
            }
        }
    }
}
