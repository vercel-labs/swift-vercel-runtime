/// Percent-encodes every UTF-8 byte of `value` outside the RFC 3986 unreserved set
/// (`A-Z a-z 0-9 - . _ ~`), so the result is safe as one path segment or one query name or value.
///
/// ```swift
/// percentEncoded("a b/c?d") // "a%20b%2Fc%3Fd"
/// ```
package func percentEncoded(_ value: String) -> String {
    escaped(value) { isAlphanumeric($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "~") }
}

/// Percent-encodes `value` exactly like JavaScript's `encodeURIComponent`: every UTF-8 byte except
/// `A-Z a-z 0-9 - _ . ! ~ * ' ( )`. Use it where a Node library builds a URL with
/// `encodeURIComponent`, so Swift sends the same URL.
///
/// ```swift
/// uriComponentEncoded("a b/(c)!") // "a%20b%2F(c)!"
/// ```
package func uriComponentEncoded(_ value: String) -> String {
    escaped(value) { byte in
        switch byte {
        case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "!"), UInt8(ascii: "~"),
            UInt8(ascii: "*"), UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"):
            true
        default:
            isAlphanumeric(byte)
        }
    }
}

/// A query string (without the leading `?`) from name-value pairs, each percent-encoded with
/// ``percentEncoded(_:)``. Pairs keep their order; names may repeat.
///
/// ```swift
/// queryString([("version", "1"), ("key", "a b"), ("key", "c")]) // "version=1&key=a%20b&key=c"
/// ```
package func queryString(_ items: [(name: String, value: String)]) -> String {
    items.map { "\(percentEncoded($0.name))=\(percentEncoded($0.value))" }.joined(separator: "&")
}

/// An `application/x-www-form-urlencoded` body from name-value pairs, as browsers encode forms
/// (WHATWG URL standard): spaces become `+`, and every byte other than `A-Z a-z 0-9 * - . _` is
/// percent-encoded.
///
/// ```swift
/// formURLEncoded([("Action", "AssumeRoleWithWebIdentity"), ("RoleSessionName", "a b")])
/// // "Action=AssumeRoleWithWebIdentity&RoleSessionName=a+b"
/// ```
package func formURLEncoded(_ fields: [(name: String, value: String)]) -> String {
    fields.map { "\(formEncoded($0.name))=\(formEncoded($0.value))" }.joined(separator: "&")
}

private func formEncoded(_ value: String) -> String {
    escaped(value, spaceAsPlus: true) {
        isAlphanumeric($0) || $0 == UInt8(ascii: "*") || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_")
    }
}

private func escaped(_ value: String, spaceAsPlus: Bool = false, keeping isKept: (UInt8) -> Bool) -> String {
    let digits = Array("0123456789ABCDEF".utf8)
    var output: [UInt8] = []
    output.reserveCapacity(value.utf8.count)
    for byte in value.utf8 {
        if isKept(byte) {
            output.append(byte)
        } else if spaceAsPlus, byte == UInt8(ascii: " ") {
            output.append(UInt8(ascii: "+"))
        } else {
            output.append(UInt8(ascii: "%"))
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
    }
    return String(decoding: output, as: UTF8.self)
}

private func isAlphanumeric(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
        true
    default:
        false
    }
}

/// `url` with the user info of its authority, if any, replaced by `<redacted>`, for logs and error
/// messages.
///
/// ```swift
/// redactingUserInfo("https://user:secret@example.com/a") // "https://<redacted>@example.com/a"
/// ```
package func redactingUserInfo(_ url: String) -> String {
    let bytes = Array(url.utf8)
    guard let schemeEnd = firstIndex(of: Array("://".utf8), in: bytes) else { return url }
    let authorityStart = schemeEnd + 3
    let authorityEnd = bytes[authorityStart...].firstIndex { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#") }
        ?? bytes.endIndex
    guard let at = bytes[authorityStart..<authorityEnd].lastIndex(of: UInt8(ascii: "@")) else { return url }
    return String(decoding: bytes[..<authorityStart], as: UTF8.self) + "<redacted>" + String(decoding: bytes[at...], as: UTF8.self)
}

private func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
    guard haystack.count >= needle.count else { return nil }
    return (0...(haystack.count - needle.count)).first { haystack[$0..<($0 + needle.count)].elementsEqual(needle) }
}
