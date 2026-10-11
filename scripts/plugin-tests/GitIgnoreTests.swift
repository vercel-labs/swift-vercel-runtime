// Tests for Plugins/VercelPlugin/GitIgnore.swift (`init` keeping .vercel out of Git).
// Run by scripts/test-plugin.sh.
import Foundation

/// Returns the number of failures.
func runGitIgnoreTests() -> Int {
    var failures = 0
    func expect(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)\(detail().isEmpty ? "" : "\n" + detail())")
        }
    }

    // ignoresVercelDirectory
    for pattern in [".vercel", ".vercel/", "/.vercel", "/.vercel/", ".vercel/*", "**/.vercel", "/.vercel/output"] {
        expect("ignores: \(pattern)", GitIgnore.ignoresVercelDirectory(".build/\n\(pattern)\nPackage.resolved\n"))
    }
    expect("ignores: surrounding spaces", GitIgnore.ignoresVercelDirectory("  .vercel  \n"))
    expect("ignores: CRLF", GitIgnore.ignoresVercelDirectory(".build/\r\n.vercel\r\n"))
    expect("not ignored: empty", !GitIgnore.ignoresVercelDirectory(""))
    expect("not ignored: other entries", !GitIgnore.ignoresVercelDirectory(".build/\n/Packages\n.env*\n"))
    expect("not ignored: comment", !GitIgnore.ignoresVercelDirectory("# .vercel\n"))
    expect("not ignored: similar names", !GitIgnore.ignoresVercelDirectory(".vercelignore\nvercel\n.vercel-old\n"))
    expect("not ignored: re-included later", !GitIgnore.ignoresVercelDirectory(".vercel\n!.vercel\n"))
    expect("ignored: re-included then ignored again", GitIgnore.ignoresVercelDirectory(".vercel\n!.vercel\n.vercel/\n"))

    // addingEntry
    expect("add: new file", GitIgnore.addingEntry(to: nil) == ".vercel\n")
    expect("add: empty file", GitIgnore.addingEntry(to: "") == ".vercel\n")
    expect("add: keeps contents, trailing newline", GitIgnore.addingEntry(to: ".build/\n") == ".build/\n.vercel\n")
    expect("add: no trailing newline", GitIgnore.addingEntry(to: ".build/") == ".build/\n.vercel\n")
    expect("add: CRLF", GitIgnore.addingEntry(to: ".build/\r\n") == ".build/\r\n.vercel\r\n")
    expect("add: CRLF without trailing newline", GitIgnore.addingEntry(to: ".build/\r\n/Packages") == ".build/\r\n/Packages\r\n.vercel\r\n")
    let added = GitIgnore.addingEntry(to: "# Swift\n.build/\n\n# Secrets\n.env*\n")
    expect("add: everything before stays", added.hasPrefix("# Swift\n.build/\n\n# Secrets\n.env*\n"))
    expect("add: result is ignored", GitIgnore.ignoresVercelDirectory(added))

    return failures
}
