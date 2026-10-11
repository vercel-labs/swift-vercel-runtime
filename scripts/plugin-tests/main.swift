// Tests for the PackagePlugin-free sources of Plugins/VercelPlugin. Plugin sources cannot be
// imported by test targets, so scripts/test-plugin.sh compiles them with the files in this
// directory and runs the result. Top-level code must be in main.swift.
import Foundation

let groups: [(name: String, run: () -> Int)] = [
    ("VercelJSON", runVercelJSONTests),
    ("ToolchainCheck and SwiftVersionFile", runToolchainCheckTests),
]
var failures = 0
for group in groups {
    print("== \(group.name)")
    failures += group.run()
}
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
