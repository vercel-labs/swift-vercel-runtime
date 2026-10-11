// Tests for Plugins/VercelPlugin/VercelJSON.swift (the vercel.json edits of `swift package vercel init`).
// Run by scripts/test-plugin.sh.
import Foundation

/// Returns the number of failures.
func runVercelJSONTests() -> Int {
    let install = VercelJSON.installCommand
    let build = VercelJSON.buildCommand(options: [])
    let settings = [(key: "installCommand", value: install), (key: "buildCommand", value: build)]
    var failures = 0

    func check(_ name: String, _ input: String?, expect expected: String? = nil, changes expectedChanges: [VercelJSON.Change]? = nil) {
        do {
            let (text, changes) = try VercelJSON.setting(settings, in: input)
            var problems: [String] = []
            if let expected, text != expected { problems.append("text:\n\(text)\n--- expected:\n\(expected)") }
            if let expectedChanges, changes.map(\.change) != expectedChanges { problems.append("changes: \(changes.map(\.change))") }
            // Always: valid JSON with both settings, every other member unchanged.
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            if object?["installCommand"] as? String != install || object?["buildCommand"] as? String != build {
                problems.append("settings missing in:\n\(text)")
            }
            if let input, var before = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any], var after = object {
                for key in ["installCommand", "buildCommand"] { before[key] = nil; after[key] = nil }
                // Compared as canonical JSON: NSDictionary equality is unreliable for numbers and booleans
                // on Linux.
                func canonical(_ object: [String: Any]) -> Data? {
                    try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                }
                if canonical(before) != canonical(after) { problems.append("other settings changed") }
            }
            if problems.isEmpty { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)\n" + problems.joined(separator: "\n")) }
        } catch {
            failures += 1
            print("FAIL  \(name): threw \(error)")
        }
    }

    func checkThrows(_ name: String, _ input: String) {
        do {
            _ = try VercelJSON.setting(settings, in: input)
            failures += 1
            print("FAIL  \(name): did not throw")
        } catch {
            print("PASS  \(name) (\(error))")
        }
    }

    let i = "\"installCommand\": \"\(install)\""
    let b = "\"buildCommand\": \"\(build)\""

    check("no vercel.json", nil, expect: "{\n  \(i),\n  \(b)\n}\n", changes: [.added, .added])

    check("example vercel.json (crons)",
          "{\n  \"crons\": [{ \"path\": \"/cron\", \"schedule\": \"0 5 * * *\" }]\n}\n",
          expect: "{\n  \(i),\n  \(b),\n  \"crons\": [{ \"path\": \"/cron\", \"schedule\": \"0 5 * * *\" }]\n}\n",
          changes: [.added, .added])

    let configured = "{\n  \"crons\": [],\n  \(i),\n  \(b)\n}\n"
    check("already configured: byte-identical", configured, expect: configured, changes: [.unchanged, .unchanged])

    check("custom build command replaced in place, install added",
          "{\n    \"regions\": [\"iad1\"],\n    \"buildCommand\": \"swift build\",\n    \"headers\": [{\"source\": \"/(.*)\", \"headers\": [{\"key\": \"x\", \"value\": \"}{\\\"\"}]}]\n}",
          expect: "{\n    \(i),\n    \"regions\": [\"iad1\"],\n    \(b),\n    \"headers\": [{\"source\": \"/(.*)\", \"headers\": [{\"key\": \"x\", \"value\": \"}{\\\"\"}]}]\n}",
          changes: [.added, .updated(from: "swift build")])

    check("null value replaced", "{\"installCommand\": null, \(b)}",
          expect: "{\"installCommand\": \"\(install)\", \(b)}", changes: [.updated(from: "null"), .unchanged])

    check("empty object", "{}", expect: "{\n  \(i),\n  \(b)\n}", changes: [.added, .added])
    check("empty object with space and newline", "{ }\n", expect: "{\n  \(i),\n  \(b)\n}\n")

    check("single line", "{\"crons\":[{\"path\":\"/c\",\"schedule\":\"0 5 * * *\"}]}",
          expect: "{\(i),\(b),\"crons\":[{\"path\":\"/c\",\"schedule\":\"0 5 * * *\"}]}")
    check("single line with spaces", "{ \"cleanUrls\": true }", expect: "{ \(i), \(b), \"cleanUrls\": true }")

    check("tabs", "{\n\t\"cleanUrls\": true\n}", expect: "{\n\t\(i),\n\t\(b),\n\t\"cleanUrls\": true\n}")
    check("CRLF", "{\r\n  \"cleanUrls\": true\r\n}\r\n", expect: "{\r\n  \(i),\r\n  \(b),\r\n  \"cleanUrls\": true\r\n}\r\n")
    check("blank line before first member", "{\n\n  \"cleanUrls\": true\n}", expect: "{\n  \(i),\n  \(b),\n\n  \"cleanUrls\": true\n}")

    check("nested installCommand is not top-level",
          "{\n  \"functions\": { \"api/x\": { \"installCommand\": \"nested\" } },\n  \"buildCommand\": \"make\"\n}",
          expect: "{\n  \(i),\n  \"functions\": { \"api/x\": { \"installCommand\": \"nested\" } },\n  \(b)\n}",
          changes: [.added, .updated(from: "make")])

    check("escaped key", "{\"build\\u0043ommand\": \"make\", \"a\": 1}",
          expect: "{\(i),\"build\\u0043ommand\": \"\(build)\", \"a\": 1}", changes: [.added, .updated(from: "make")])

    check("numbers and literals", "{\"a\": -1.5e3, \"b\": false, \"c\": null, \"installCommand\": 1}",
          expect: "{\(b),\"a\": -1.5e3, \"b\": false, \"c\": null, \"installCommand\": \"\(install)\"}")

    check("byte order mark", "\u{FEFF}{\"cleanUrls\": true}", expect: "\u{FEFF}{\(i),\(b),\"cleanUrls\": true}")

    checkThrows("invalid JSON (comment)", "{\n  // comment\n  \"a\": 1\n}")
    checkThrows("trailing comma", "{\"a\": 1,}")
    checkThrows("not an object", "[1, 2]")

    let quoted = VercelJSON.buildCommand(options: ["--product", "App", "--region", "iad1", "--static-dir", "My Public", "--x", "it's"])
    let expectedQuoted = ".vercel/bin/swift package --disable-sandbox vercel --product App --region iad1 --static-dir 'My Public' --x 'it'\\''s'"
    if quoted == expectedQuoted { print("PASS  build command quoting") } else { failures += 1; print("FAIL  build command quoting: \(quoted)") }
    return failures
}
