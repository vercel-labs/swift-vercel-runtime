/// Decodes base64url (RFC 4648 §5), the encoding of JWT segments, with or without `=` padding.
///
/// Also accepts the standard alphabet's `+` and `/`, like Node's `Buffer`. Returns `nil` for any
/// other character or an impossible length.
///
/// ```swift
/// base64URLDecoded("eyJhIjoxfQ") // Array(#"{"a":1}"#.utf8)
/// ```
func base64URLDecoded(_ string: some StringProtocol) -> [UInt8]? {
    var input = Array(string.utf8)
    var padding = 0
    while input.last == UInt8(ascii: "="), padding < 2 {
        input.removeLast()
        padding += 1
    }
    // A single leftover character carries only 6 bits: not a whole byte.
    guard input.count % 4 != 1 else { return nil }
    if padding > 0, (input.count + padding) % 4 != 0 { return nil }

    var output: [UInt8] = []
    output.reserveCapacity(input.count * 3 / 4)
    var buffer: UInt32 = 0
    var bits = 0
    for byte in input {
        guard let value = base64Value(byte) else { return nil }
        buffer = buffer << 6 | UInt32(value)
        bits += 6
        if bits >= 8 {
            bits -= 8
            output.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
        }
    }
    return output
}

private func base64Value(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"): byte - UInt8(ascii: "A")
    case UInt8(ascii: "a")...UInt8(ascii: "z"): byte - UInt8(ascii: "a") + 26
    case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0") + 52
    case UInt8(ascii: "-"), UInt8(ascii: "+"): 62
    case UInt8(ascii: "_"), UInt8(ascii: "/"): 63
    default: nil
    }
}
