extension RuntimeCache {
    /// The default key hash, the same as `getCache()` in `@vercel/functions`, so Swift and Node
    /// functions share entries: djb2 over the key's UTF-16 code units with JavaScript's 32-bit
    /// integer semantics, as lowercase hexadecimal without padding.
    ///
    /// ```swift
    /// RuntimeCache.defaultKeyHash("user:1") // "6935999f"
    /// ```
    public static func defaultKeyHash(_ key: String) -> String {
        // JavaScript: `hash = hash * 33 ^ key.charCodeAt(i)`, where `^` truncates its operands to
        // signed 32-bit integers, then `(hash >>> 0).toString(16)`.
        var hash: Int32 = 5381
        for unit in key.utf16 {
            hash = Int32(truncatingIfNeeded: Int64(hash) * 33) ^ Int32(unit)
        }
        return String(UInt32(bitPattern: hash), radix: 16)
    }

    /// The key the cache stores `key` under: the hashed key, prefixed with the namespace and its
    /// separator when there is a namespace.
    ///
    /// ```swift
    /// RuntimeCache(namespace: "users").storageKey(for: "user:1") // "users$6935999f"
    /// ```
    public func storageKey(for key: String) -> String {
        let hash = keyHashFunction(key)
        // Like Node, an empty namespace means none and an empty separator means the default.
        guard let namespace, !namespace.isEmpty else { return hash }
        let separator = namespaceSeparator.isEmpty ? Self.defaultNamespaceSeparator : namespaceSeparator
        return "\(namespace)\(separator)\(hash)"
    }
}
