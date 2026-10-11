package import HTTPTypes

/// What ``HTTPFields/extractVercelInternalFields()`` took out of a request that the bootstrap
/// still needs.
package struct VercelInternalFields: Sendable, Equatable {
    /// The invocation the request belongs to. `nil` when the request carries no invocation id,
    /// which means it did not come through the Vercel functions runtime.
    package var invocation: InvocationContext?
    /// The runtime cache configuration (`x-vercel-sc-*`, keyed by lowercased name) hidden from
    /// the app because the proxy set `x-vercel-sc-no-header-leak`. Empty otherwise.
    package var hiddenRuntimeCacheFields: [String: String]

    package init(invocation: InvocationContext?, hiddenRuntimeCacheFields: [String: String] = [:]) {
        self.invocation = invocation
        self.hiddenRuntimeCacheFields = hiddenRuntimeCacheFields
    }
}

extension HTTPFields {
    /// Removes the headers the Vercel functions runtime adds for itself and returns the
    /// invocation they identify.
    ///
    /// Matches the Node.js and Python runtimes:
    /// - every `x-vercel-internal-*` header is removed,
    /// - `x-vercel-internal-oidc-token` is exposed as `x-vercel-oidc-token` unless the request
    ///   already has one,
    /// - `x-vercel-internal-deadline` is exposed as `x-vercel-deadline` unless it is empty; a
    ///   client-sent `x-vercel-deadline` is always removed,
    /// - `x-vercel-sc-runtime-cache` is always removed, and the other runtime cache headers
    ///   (`x-vercel-sc-*`) are removed when `x-vercel-sc-no-header-leak` is set. Repeated hidden
    ///   headers are joined with `, `, as `HTTPFields` joins them when they are visible.
    ///
    /// Returns `nil` when the request carries no invocation id, which means it did not come
    /// through the Vercel functions runtime.
    package mutating func removeVercelInternalFields() -> InvocationContext? {
        extractVercelInternalFields().invocation
    }

    /// Like ``removeVercelInternalFields()``, but also returns the runtime cache configuration it
    /// hid from the app, so the bootstrap can hand it to the app over its socket.
    package mutating func extractVercelInternalFields() -> VercelInternalFields {
        var invocationID: String?
        var requestID: String?
        var oidcToken: String?
        var deadline: String?
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
                case VercelHeader.internalDeadline: deadline = field.value
                default: break
                }
            } else if name == VercelHeader.runtimeCache || name == VercelHeader.deadline {
                // The deadline is only trusted from the runtime.
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

        var hidden: [String: String] = [:]
        if hideRuntimeCacheFields {
            modified = true
            for field in runtimeCacheFields where field.name.canonicalName != VercelHeader.runtimeCacheNoHeaderLeak {
                // Repeated headers are joined like `HTTPFields`' subscript joins them for the app
                // when they are visible, so both modes yield the same configuration.
                let name = field.name.canonicalName
                hidden[name] = hidden[name].map { "\($0), \(field.value)" } ?? field.value
            }
        } else {
            kept.append(contentsOf: runtimeCacheFields)
        }

        if let oidcToken, let name = HTTPField.Name(VercelHeader.oidcToken), kept[name] == nil {
            kept.append(HTTPField(name: name, value: oidcToken))
        }
        if let deadline, !deadline.isEmpty, let name = HTTPField.Name(VercelHeader.deadline) {
            kept.append(HTTPField(name: name, value: deadline))
        }
        if modified {
            self = kept
        }
        return VercelInternalFields(
            invocation: InvocationContext(invocationID: invocationID, requestID: requestID),
            hiddenRuntimeCacheFields: hidden
        )
    }
}

/// Header names used by the Vercel functions runtime.
package enum VercelHeader {
    package static let internalPrefix = "x-vercel-internal-"
    package static let invocationID = "x-vercel-internal-invocation-id"
    package static let requestID = "x-vercel-internal-request-id"
    package static let internalOIDCToken = "x-vercel-internal-oidc-token"
    /// Public OIDC header exposed to user code, derived from the internal one.
    package static let oidcToken = "x-vercel-oidc-token"
    /// When the runtime will time the request out (RFC 3339).
    package static let internalDeadline = "x-vercel-internal-deadline"
    /// Public deadline header exposed to user code, derived from the internal one.
    package static let deadline = "x-vercel-deadline"

    /// Runtime cache configuration headers. `x-vercel-sc-runtime-cache` is always removed; the
    /// others are removed when the proxy sets ``runtimeCacheNoHeaderLeak``.
    package static let runtimeCache = "x-vercel-sc-runtime-cache"
    package static let runtimeCacheNoHeaderLeak = "x-vercel-sc-no-header-leak"
    package static let runtimeCacheHeaders = "x-vercel-sc-headers"
    package static let runtimeCacheHost = "x-vercel-sc-host"
    package static let runtimeCacheBasePath = "x-vercel-sc-basepath"
    package static let runtimeCacheProtocol = "x-vercel-sc-protocol"
    /// The runtime cache configuration handed to the app, as headers or over the bootstrap socket.
    package static let runtimeCacheFields = [runtimeCacheHeaders, runtimeCacheHost, runtimeCacheBasePath, runtimeCacheProtocol]
    package static let runtimeCacheConfiguration = Set(runtimeCacheFields + [runtimeCacheNoHeaderLeak])

    /// The health check path. Answer with 200 and send no IPC messages.
    package static let pingPath = "/_vercel/ping"

    /// Whether a lowercased header name is internal and must not reach user code.
    package static func isInternal(_ lowercasedName: String) -> Bool {
        lowercasedName.hasPrefix(internalPrefix)
    }
}
