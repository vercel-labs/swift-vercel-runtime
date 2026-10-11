import Synchronization

/// The process-wide cache ``RuntimeCache`` falls back to when the Vercel Runtime Cache is not
/// available, for example locally. Same semantics as Node's `InMemoryCache`: entries hold the
/// JSON-encoded value, expire `ttl` after they were set, and ``expireTags(_:)`` removes every entry
/// with any of the tags.
package final class InMemoryRuntimeCache: Sendable {
    /// The cache every ``RuntimeCache`` shares.
    package static let shared = InMemoryRuntimeCache()

    private struct Entry {
        var value: [UInt8]
        var expiresAt: ContinuousClock.Instant?
        var tags: Set<String>
    }

    private let entries = Mutex<[String: Entry]>([:])
    private let warnedUnavailable = Mutex(false)
    private let now: @Sendable () -> ContinuousClock.Instant

    /// - Parameter now: The current time, injectable to test expiry.
    package init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// The JSON value stored under `key`, `nil` when missing or expired.
    package func get(_ key: String) -> [UInt8]? {
        let now = now()
        return entries.withLock { entries in
            guard let entry = entries[key] else { return nil }
            // Like Node: still fresh at exactly `ttl` after it was set.
            if let expiresAt = entry.expiresAt, expiresAt < now {
                entries[key] = nil
                return nil
            }
            return entry.value
        }
    }

    /// Stores the JSON `value` under `key`. Like Node, a `nil` or zero `ttl` never expires and a
    /// negative one has already expired: the next read finds nothing.
    package func set(_ key: String, value: [UInt8], ttl: Duration?, tags: [String]) {
        let expiresAt = ttl.flatMap { $0 != .zero ? now() + $0 : nil }
        entries.withLock { $0[key] = Entry(value: value, expiresAt: expiresAt, tags: Set(tags)) }
    }

    package func delete(_ key: String) {
        _ = entries.withLock { $0.removeValue(forKey: key) }
    }

    /// Removes every entry tagged with any of `tags`.
    package func expireTags(_ tags: [String]) {
        let tags = Set(tags)
        entries.withLock { entries in
            entries = entries.filter { $0.value.tags.isDisjoint(with: tags) }
        }
    }

    /// The number of entries, expired or not.
    package var count: Int {
        entries.withLock { $0.count }
    }

    /// `true` the first time it is called, `false` after: the warning that the Runtime Cache is
    /// unavailable is logged once per process.
    package func shouldWarnUnavailable() -> Bool {
        warnedUnavailable.withLock { warned in
            defer { warned = true }
            return !warned
        }
    }
}
