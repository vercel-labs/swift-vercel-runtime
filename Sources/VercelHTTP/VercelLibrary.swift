/// Facts about this library that the feature modules send to Vercel.
package enum VercelLibrary {
    /// This package's release, sent in `User-Agent` and SDK headers.
    ///
    /// Bump it together with `VercelJSON.release` in `Plugins/VercelPlugin/VercelJSON.swift` at
    /// every release: the plugin can't import package targets, so it keeps its own copy.
    package static let version = "0.6.1"
}
