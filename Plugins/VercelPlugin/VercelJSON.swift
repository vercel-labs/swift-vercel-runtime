import Foundation

/// Sets top-level settings in `vercel.json` for `swift package vercel init`, leaving the rest of the
/// file exactly as it was: only the values of those settings change (or new members are added
/// after the opening brace), so key order, formatting and every other setting stay untouched.
///
/// Kept free of `PackagePlugin` so the logic can be compiled and tested on its own.
enum VercelJSON {
    /// This package's release. The Install Command runs the install script from this release's tag,
    /// so it always matches the plugin. Update it (and the README) with every release.
    ///
    /// Bump it together with `VercelLibrary.version` in `Sources/VercelHTTP/VercelLibrary.swift`:
    /// the plugin can't import package targets, so the two copies must be kept in sync by hand.
    static let release = "0.6.0"

    /// Install Command for Git deployments: installs Swift in Vercel's build cache.
    static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/vercel-labs/swift-vercel-runtime/\(release)/scripts/vercel-install-swift.sh | bash"

    /// Build Command for Git deployments, with optional `swift package vercel` build options.
    static func buildCommand(options: [String]) -> String {
        ([".vercel/bin/swift", "package", "--disable-sandbox", "vercel"] + options.map(shellQuoted))
            .joined(separator: " ")
    }

    enum Change: Equatable {
        case added
        case updated(from: String)
        case unchanged
    }

    struct EditError: Error, CustomStringConvertible {
        let description: String
    }

    /// Returns `original` (the contents of `vercel.json`, or `nil` if there is none) with each
    /// setting set to its value, and what changed for each.
    static func setting(
        _ settings: [(key: String, value: String)],
        in original: String?
    ) throws -> (text: String, changes: [(key: String, change: Change)]) {
        guard let original else {
            let members = settings.map { "  \(encoded($0.key)): \(encoded($0.value))" }
            return ("{\n" + members.joined(separator: ",\n") + "\n}\n", settings.map { ($0.key, .added) })
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(original.utf8))
        } catch {
            throw EditError(description: "vercel.json is not valid JSON")
        }
        guard let object = parsed as? [String: Any] else {
            throw EditError(description: "vercel.json must contain a JSON object")
        }

        let bytes = Array(original.utf8)
        var scanner = Scanner(bytes: bytes)
        let (open, close, members) = try scanner.topLevelObject()

        var replacements: [(range: Range<Int>, text: String)] = []
        var missing: [(key: String, value: String)] = []
        var changes: [(key: String, change: Change)] = []
        for (key, value) in settings {
            // With duplicate keys, JSON parsers use the last one.
            if let member = members.last(where: { $0.key == key }) {
                if let current = object[key] as? String, current == value {
                    changes.append((key, .unchanged))
                } else {
                    replacements.append((member.valueRange, encoded(value)))
                    changes.append((key, .updated(from: describe(object[key]))))
                }
            } else {
                missing.append((key, value))
                changes.append((key, .added))
            }
        }

        if !missing.isEmpty {
            let newMembers = missing.map { "\(encoded($0.key)): \(encoded($0.value))" }
            if members.isEmpty {
                // `{}`: lay the members out one per line.
                let newline = original.contains("\r\n") ? "\r\n" : "\n"
                let text = "{" + newline + newMembers.map { "  " + $0 }.joined(separator: "," + newline) + newline + "}"
                replacements.append((open..<(close + 1), text))
            } else {
                // Insert before the first member, laid out like it: on its own line with the same
                // indentation, or on the same line.
                var first = open + 1
                while first < bytes.count, Scanner.isWhitespace(bytes[first]) { first += 1 }
                let whitespace = String(decoding: bytes[(open + 1)..<first], as: UTF8.self)
                let separator: String
                if let lastNewline = whitespace.lastIndex(of: "\n") {
                    let newline = whitespace.contains("\r\n") ? "\r\n" : "\n"
                    separator = newline + whitespace[whitespace.index(after: lastNewline)...]
                } else {
                    separator = whitespace
                }
                replacements.append(((open + 1)..<(open + 1), newMembers.map { separator + $0 + "," }.joined()))
            }
        }

        var result = bytes
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(replacement.range, with: Array(replacement.text.utf8))
        }
        return (String(decoding: result, as: UTF8.self), changes)
    }

    /// A shell word for `argument`, quoted only when needed.
    static func shellQuoted(_ argument: String) -> String {
        let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,@%+")
        if !argument.isEmpty && argument.allSatisfy(plain.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func encoded(_ string: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func describe(_ value: Any?) -> String {
        guard let value else { return "null" }
        if let string = value as? String { return string }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Finds the members of the top-level object in already validated JSON.
    private struct Scanner {
        struct Member {
            let key: String
            let valueRange: Range<Int>
        }

        let bytes: [UInt8]
        var index = 0

        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        mutating func topLevelObject() throws -> (open: Int, close: Int, members: [Member]) {
            skipWhitespace()
            // A UTF-8 byte order mark.
            if bytes[index...].starts(with: [0xEF, 0xBB, 0xBF]) {
                index += 3
                skipWhitespace()
            }
            let open = index
            try expect(UInt8(ascii: "{"))
            var members: [Member] = []
            skipWhitespace()
            if try peek() == UInt8(ascii: "}") { return (open, index, members) }
            while true {
                skipWhitespace()
                let keyStart = index
                try skipString()
                let keyData = Data(bytes[keyStart..<index])
                guard let key = try JSONSerialization.jsonObject(with: keyData, options: .fragmentsAllowed) as? String else {
                    throw EditError(description: "could not read vercel.json")
                }
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                skipWhitespace()
                let valueStart = index
                try skipValue()
                members.append(Member(key: key, valueRange: valueStart..<index))
                skipWhitespace()
                switch try peek() {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "}"): return (open, index, members)
                default: throw EditError(description: "could not read vercel.json")
                }
            }
        }

        private mutating func skipWhitespace() {
            while index < bytes.count, Self.isWhitespace(bytes[index]) { index += 1 }
        }

        private func peek() throws -> UInt8 {
            guard index < bytes.count else { throw EditError(description: "could not read vercel.json") }
            return bytes[index]
        }

        private mutating func expect(_ byte: UInt8) throws {
            guard try peek() == byte else { throw EditError(description: "could not read vercel.json") }
            index += 1
        }

        private mutating func skipString() throws {
            try expect(UInt8(ascii: "\""))
            while true {
                let byte = try peek()
                index += 1
                if byte == UInt8(ascii: "\\") {
                    index += 1
                } else if byte == UInt8(ascii: "\"") {
                    return
                }
            }
        }

        private mutating func skipValue() throws {
            switch try peek() {
            case UInt8(ascii: "\""):
                try skipString()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                repeat {
                    switch try peek() {
                    case UInt8(ascii: "\""):
                        try skipString()
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                    default:
                        break
                    }
                    index += 1
                } while depth > 0
            default:
                // Numbers, true, false and null.
                while index < bytes.count, !Self.isWhitespace(bytes[index]),
                    ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(bytes[index])
                {
                    index += 1
                }
            }
        }
    }
}
