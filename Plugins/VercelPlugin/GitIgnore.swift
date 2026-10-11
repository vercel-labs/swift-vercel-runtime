import Foundation

/// Makes sure `swift package vercel init` leaves `.vercel` out of Git.
///
/// The build writes `.vercel/output` (and `vercel link` writes `.vercel/project.json`) next to
/// Package.swift, so `.vercel` belongs in `.gitignore`, as `vercel link` sets it up. `init` asks
/// Git first (`git check-ignore`, which also sees a parent directory's `.gitignore`), and only when
/// that's not possible reads the package's own `.gitignore` with ``ignoresVercelDirectory(_:)``.
///
/// Kept free of `PackagePlugin` so the logic can be compiled and tested on its own.
enum GitIgnore {
    static let name = ".gitignore"
    static let entry = ".vercel"
    /// The path asked about: a directory the build writes, so directory-only patterns apply too.
    static let checkedPath = ".vercel/output"

    /// Patterns, relative to the `.gitignore` next to Package.swift, that ignore `.vercel/output`.
    private static let ignoringPatterns: Set<String> = [
        ".vercel", ".vercel/", "/.vercel", "/.vercel/",
        ".vercel/*", "/.vercel/*", ".vercel/**", "/.vercel/**",
        "**/.vercel", "**/.vercel/",
        ".vercel/output", ".vercel/output/", "/.vercel/output", "/.vercel/output/",
    ]

    /// Whether `.gitignore` contents next to Package.swift ignore the `.vercel` build output. Used
    /// when Git can't answer (no Git, or not a repository). Like Git, the last matching line wins,
    /// so a later `!.vercel` re-includes it.
    static func ignoresVercelDirectory(_ contents: String) -> Bool {
        var ignored = false
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("!") {
                if ignoringPatterns.contains(String(line.dropFirst())) { ignored = false }
            } else if ignoringPatterns.contains(line) {
                ignored = true
            }
        }
        return ignored
    }

    /// `contents` (or a new file for `nil`) with `.vercel` added on its own line at the end,
    /// leaving everything before it as it was.
    static func addingEntry(to contents: String?) -> String {
        guard let contents, !contents.isEmpty else { return entry + "\n" }
        // Compared as bytes: in Swift "\r\n" is one Character, so `hasSuffix("\n")` misses it.
        let newline = contents.contains("\r\n") ? "\r\n" : "\n"
        let separator = contents.utf8.last == UInt8(ascii: "\n") ? "" : newline
        return contents + separator + entry + newline
    }
}
