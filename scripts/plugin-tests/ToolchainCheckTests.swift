// Tests for Plugins/VercelPlugin/ToolchainCheck.swift (the toolchain/SDK preflight check) and
// Plugins/VercelPlugin/SwiftVersionFile.swift (what `init` does with .swift-version).
// Run by scripts/test-plugin.sh.
import Foundation

/// Returns the number of failures.
func runToolchainCheckTests() -> Int {
    var failures = 0
    func expect(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)\(detail().isEmpty ? "" : "\n" + detail())")
        }
    }
    func contains(_ text: String?, _ parts: [String]) -> Bool {
        guard let text else { return false }
        return parts.allSatisfy(text.contains)
    }

    let apple = "swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)\nTarget: arm64-apple-macosx27.0.0"
    let applePatch = "Apple Swift version 6.2.3 (swiftlang-6.2.3.3.21 clang-1700.6.3.2)\nTarget: arm64-apple-macosx26.0"
    let appleUnparseable = "Apple Swift version 7.0-dev (swiftlang-7.0.0.1.2 clang-2200.0.1.1)\nTarget: arm64-apple-macosx27.0.0"
    let release64 = "Apple Swift version 6.4 (swift-6.4-RELEASE)\nTarget: arm64-apple-macosx27.0.0"
    let release633 = "Swift version 6.3.3 (swift-6.3.3-RELEASE)\nTarget: aarch64-unknown-linux-gnu"
    let release63 = "Swift version 6.3 (swift-6.3-RELEASE)\nTarget: aarch64-unknown-linux-gnu"
    let snapshot = "Apple Swift version 6.5-dev (LLVM 1a2b3c, Swift 4d5e6f)\nTarget: arm64-apple-macosx27.0.0"
    let snapshotTag = "Swift version 6.5-dev (swift-DEVELOPMENT-SNAPSHOT-2026-10-01-a)\nTarget: x86_64-unknown-linux-gnu"
    let sdk640 = "swift-6.4.0-RELEASE_static-linux-0.1.0\nswift-6.4.0-RELEASE_wasm\n"
    let sdk633 = "swift-6.3.3-RELEASE_static-linux-0.1.0\n"
    let sdk63 = "swift-6.3-RELEASE_static-linux-0.1.0\n"

    // releaseVersion
    expect("releaseVersion: 6.4 -> 6.4.0", ToolchainCheck.releaseVersion(in: release64) == "6.4.0")
    expect("releaseVersion: 6.3.3", ToolchainCheck.releaseVersion(in: release633) == "6.3.3")
    expect("releaseVersion: Apple toolchain is nil", ToolchainCheck.releaseVersion(in: apple) == nil)
    expect("releaseVersion: snapshot is nil", ToolchainCheck.releaseVersion(in: snapshot) == nil)
    expect("releaseVersion: snapshot tag is nil", ToolchainCheck.releaseVersion(in: snapshotTag) == nil)
    expect("releaseVersion: empty is nil", ToolchainCheck.releaseVersion(in: "") == nil)
    expect("releaseVersion: malformed is nil", ToolchainCheck.releaseVersion(in: "(swift-6.x-RELEASE)") == nil)

    // appleVersion and sdkReleaseVersion
    expect("appleVersion: 6.4", ToolchainCheck.appleVersion(in: apple) == "6.4")
    expect("appleVersion: 6.2.3 -> 6.2", ToolchainCheck.appleVersion(in: applePatch) == "6.2")
    expect("appleVersion: unparseable is nil", ToolchainCheck.appleVersion(in: appleUnparseable) == nil)
    expect("appleVersion: swift.org toolchain is nil", ToolchainCheck.appleVersion(in: release64) == nil)
    expect("sdkReleaseVersion: 6.4.0", ToolchainCheck.sdkReleaseVersion("swift-6.4.0-RELEASE_static-linux-0.1.0") == "6.4.0")
    expect("sdkReleaseVersion: 6.3 -> 6.3.0", ToolchainCheck.sdkReleaseVersion("swift-6.3-RELEASE_static-linux-0.1.0") == "6.3.0")
    expect("sdkReleaseVersion: snapshot is nil",
           ToolchainCheck.sdkReleaseVersion("swift-DEVELOPMENT-SNAPSHOT-2026-10-01-a_static-linux-0.1.0") == nil)

    // problem: Apple toolchain
    let appleProblem = ToolchainCheck.problem(swiftVersionOutput: apple, sdkListOutput: sdk640)
    expect("Apple toolchain: swiftly install/use 6.4",
           contains(appleProblem, ["Apple's toolchain", "swiftly install 6.4\n", "swiftly use 6.4\n", "Apple Swift version 6.4 (swiftlang-"]),
           appleProblem ?? "nil")
    expect("Apple toolchain: no hardcoded patch release", appleProblem?.contains("6.4.0\n") == false)
    let appleUnparseableProblem = ToolchainCheck.problem(swiftVersionOutput: appleUnparseable, sdkListOutput: nil)
    expect("Apple toolchain, unparseable version: swiftly install/use latest",
           contains(appleUnparseableProblem, ["swiftly install latest\n", "swiftly use latest\n"]),
           appleUnparseableProblem ?? "nil")

    // problem: SDKs
    let missing = ToolchainCheck.problem(swiftVersionOutput: release64, sdkListOutput: "swift-6.4.0-RELEASE_wasm\n")
    expect("missing SDK: swift.org instructions for 6.4.0",
           contains(missing, ["not installed", "Static Linux SDK for Swift 6.4.0", "`swift sdk install`", "checksum",
                              "\"Swift SDK for Static Linux\"", ToolchainCheck.installGuide]),
           missing ?? "nil")
    expect("missing SDK: no guessed download URL", missing?.contains("download.swift.org") == false, missing ?? "nil")
    let missingSnapshot = ToolchainCheck.problem(swiftVersionOutput: snapshot, sdkListOutput: "")
    expect("missing SDK, snapshot: generic instructions",
           contains(missingSnapshot, ["not installed", "matches your toolchain", ToolchainCheck.installGuide]),
           missingSnapshot ?? "nil")

    let mismatched = ToolchainCheck.problem(swiftVersionOutput: release64, sdkListOutput: sdk633)
    expect("mismatched SDK: lists it and asks for 6.4.0",
           contains(mismatched, ["does not match", "Swift 6.4.0", "swift-6.3.3-RELEASE_static-linux-0.1.0",
                                 "Static Linux SDK for Swift 6.4.0"]),
           mismatched ?? "nil")
    let mismatchedOlder = ToolchainCheck.problem(swiftVersionOutput: release633, sdkListOutput: sdk640)
    expect("mismatched SDK: newer SDK for older toolchain", contains(mismatchedOlder, ["Swift 6.3.3"]), mismatchedOlder ?? "nil")

    expect("matching SDK", ToolchainCheck.problem(swiftVersionOutput: release64, sdkListOutput: sdk640) == nil)
    expect("matching SDK among several",
           ToolchainCheck.problem(swiftVersionOutput: release64, sdkListOutput: sdk633 + sdk640) == nil)
    expect("matching SDK named without patch (6.3)",
           ToolchainCheck.problem(swiftVersionOutput: release63, sdkListOutput: sdk63) == nil)
    expect("explicit SDK skips the SDK checks", ToolchainCheck.problem(swiftVersionOutput: release64, sdkListOutput: nil) == nil)
    expect("snapshot toolchain with an SDK is left alone",
           ToolchainCheck.problem(swiftVersionOutput: snapshot, sdkListOutput: sdk640) == nil)
    expect("snapshot-tagged toolchain with an SDK is left alone",
           ToolchainCheck.problem(swiftVersionOutput: snapshotTag, sdkListOutput: sdk640) == nil)

    // SwiftVersionFile
    typealias Action = SwiftVersionFile.Action
    func action(_ existing: String?, _ output: String) -> Action {
        SwiftVersionFile.action(existing: existing, swiftVersionOutput: output)
    }
    expect(".swift-version: release writes the exact release", action(nil, release64) == .write("6.4.0"))
    expect(".swift-version: release 6.3.3", action(nil, release633) == .write("6.3.3"))
    expect(".swift-version: Apple toolchain writes major.minor", action(nil, apple) == .write("6.4"))
    expect(".swift-version: Apple 6.2.3 writes 6.2", action(nil, applePatch) == .write("6.2"))
    expect(".swift-version: existing file is kept", action("6.3.3\n", release64) == .keep("6.3.3"))
    expect(".swift-version: existing file is kept even for a snapshot", action("6.4", snapshot) == .keep("6.4"))
    if case .skip(let reason) = action(nil, snapshot) {
        expect(".swift-version: snapshot is skipped", reason.contains("not a Swift release") && reason.contains("6.5-dev"), reason)
    } else {
        expect(".swift-version: snapshot is skipped", false, "\(action(nil, snapshot))")
    }
    if case .skip = action(nil, appleUnparseable) { expect(".swift-version: unparseable Apple version is skipped", true) } else {
        expect(".swift-version: unparseable Apple version is skipped", false, "\(action(nil, appleUnparseable))")
    }

    let messages = [
        SwiftVersionFile.message(for: .write("6.4.0")),
        SwiftVersionFile.message(for: .write("6.4")),
        SwiftVersionFile.message(for: .keep("6.3.3")),
        SwiftVersionFile.message(for: .keep("")),
        SwiftVersionFile.message(for: action(nil, snapshot)),
    ]
    expect("message: write release", messages[0].contains("Wrote .swift-version (6.4.0): Vercel builds use Swift 6.4.0"), messages[0])
    expect("message: write major.minor", messages[1].contains("the latest Swift 6.4.x release"), messages[1])
    expect("message: keep", messages[2].contains("already exists, so it was left unchanged (Swift 6.3.3)"), messages[2])
    expect("message: keep empty", messages[3].contains("is empty"), messages[3])
    expect("message: skip", messages[4].hasPrefix("Did not write .swift-version: `swift` is not a Swift release"), messages[4])
    for message in messages { print("      " + message.replacingOccurrences(of: "\n", with: "\n      ")) }

    return failures
}
