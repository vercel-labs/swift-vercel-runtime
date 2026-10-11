/// Decodes `%XX` escapes as UTF-8, like JavaScript's `decodeURIComponent`. Returns the input
/// unchanged if it is malformed.
package func percentDecoded(_ value: String) -> String {
    // A byte search on purpose: `String.contains(_: String)` resolves to Foundation's
    // NSString API here, which would link all of Foundation and ICU (~40 MB) into static binaries.
    guard value.utf8.contains(UInt8(ascii: "%")) else { return value }
    var bytes: [UInt8] = []
    var iterator = value.utf8.makeIterator()
    while let byte = iterator.next() {
        guard byte == UInt8(ascii: "%") else {
            bytes.append(byte)
            continue
        }
        guard let high = iterator.next().flatMap(hexValue), let low = iterator.next().flatMap(hexValue) else {
            return value
        }
        bytes.append(high << 4 | low)
    }
    return String(validating: bytes, as: UTF8.self) ?? value
}

private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
    default: nil
    }
}
