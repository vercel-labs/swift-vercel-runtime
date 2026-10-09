public import HTTPTypes

extension HTTPFields {
    /// Removes the headers the Vercel functions runtime adds for itself and returns the
    /// invocation they identify.
    ///
    /// Matches the Node.js and Python runtimes:
    /// - every `x-vercel-internal-*` header is removed,
    /// - `x-vercel-internal-oidc-token` is exposed as `x-vercel-oidc-token` unless the request
    ///   already has one,
    /// - `x-vercel-sc-runtime-cache` is always removed, and the other runtime cache headers
    ///   (`x-vercel-sc-*`) are removed when `x-vercel-sc-no-header-leak` is set.
    ///
    /// Returns `nil` when the request carries no invocation id, which means it did not come
    /// through the Vercel functions runtime.
    public mutating func removeVercelInternalFields() -> InvocationContext? {
        var invocationID: String?
        var requestID: String?
        var oidcToken: String?
        var runtimeCacheFields: [HTTPField] = []
        var hideRuntimeCacheFields = false
        var kept = HTTPFields()
        var modified = false

        for field in self {
            let name = field.name.canonicalName
            if VercelHeader.isInternal(name) {
                modified = true
                switch name {
                case VercelHeader.invocationID: invocationID = field.value
                case VercelHeader.requestID: requestID = field.value
                case VercelHeader.internalOIDCToken: oidcToken = field.value
                default: break
                }
            } else if name == VercelHeader.runtimeCache {
                modified = true
            } else if VercelHeader.runtimeCacheConfiguration.contains(name) {
                // Held aside until we know whether the proxy asked to hide them.
                runtimeCacheFields.append(field)
                if name == VercelHeader.runtimeCacheNoHeaderLeak, !field.value.isEmpty {
                    hideRuntimeCacheFields = true
                }
            } else {
                kept.append(field)
            }
        }

        if hideRuntimeCacheFields {
            modified = true
        } else {
            kept.append(contentsOf: runtimeCacheFields)
        }

        if let oidcToken, let name = HTTPField.Name(VercelHeader.oidcToken), kept[name] == nil {
            kept.append(HTTPField(name: name, value: oidcToken))
        }
        if modified {
            self = kept
        }
        return InvocationContext(invocationID: invocationID, requestID: requestID)
    }
}
