/// SHA-256 (FIPS 180-4) in pure Swift, so the feature modules need neither Foundation nor a crypto
/// library for hashing keys.
///
/// ```swift
/// SHA256.hexDigest("abc") // "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
///
/// var hasher = SHA256()
/// hasher.update("ab")
/// hasher.update("c")
/// let digest = hasher.finalize() // 32 bytes
/// ```
package struct SHA256: Sendable {
    /// The digest size in bytes.
    package static let digestSize = 32

    private var state: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]
    /// Bytes waiting for a full 64-byte block.
    private var pending: [UInt8] = []
    /// The number of bytes hashed so far.
    private var length: UInt64 = 0

    package init() {}

    /// Adds `bytes` to the message.
    package mutating func update(_ bytes: some Sequence<UInt8>) {
        let handled: Void? = bytes.withContiguousStorageIfAvailable { update(buffer: $0) }
        if handled == nil {
            Array(bytes).withUnsafeBufferPointer { update(buffer: $0) }
        }
    }

    /// Adds the UTF-8 bytes of `string` to the message.
    package mutating func update(_ string: String) {
        var string = string
        string.withUTF8 { update(buffer: $0) }
    }

    /// The 32-byte digest of everything added.
    package func finalize() -> [UInt8] {
        var copy = self
        var tail = copy.pending
        let bitLength = copy.length &* 8
        tail.append(0x80)
        while tail.count % 64 != 56 {
            tail.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        tail.withUnsafeBufferPointer { buffer in
            for offset in stride(from: 0, to: buffer.count, by: 64) {
                copy.compress(UnsafeBufferPointer(rebasing: buffer[offset..<offset + 64]))
            }
        }
        var digest: [UInt8] = []
        digest.reserveCapacity(Self.digestSize)
        for word in copy.state {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }

    /// The digest of `bytes`.
    package static func hash(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        var hasher = SHA256()
        hasher.update(bytes)
        return hasher.finalize()
    }

    /// The digest of the UTF-8 bytes of `string`.
    package static func hash(_ string: String) -> [UInt8] {
        var hasher = SHA256()
        hasher.update(string)
        return hasher.finalize()
    }

    /// The digest of `bytes` as 64 lowercase hex characters.
    package static func hexDigest(_ bytes: some Sequence<UInt8>) -> String {
        hexEncoded(hash(bytes))
    }

    /// The digest of the UTF-8 bytes of `string` as 64 lowercase hex characters.
    package static func hexDigest(_ string: String) -> String {
        hexEncoded(hash(string))
    }

    private mutating func update(buffer input: UnsafeBufferPointer<UInt8>) {
        length &+= UInt64(input.count)
        var index = 0
        if !pending.isEmpty {
            let take = min(64 - pending.count, input.count)
            pending.append(contentsOf: input[0..<take])
            index = take
            guard pending.count == 64 else { return }
            let block = pending
            pending.removeAll(keepingCapacity: true)
            block.withUnsafeBufferPointer { compress($0) }
        }
        while input.count - index >= 64 {
            compress(UnsafeBufferPointer(rebasing: input[index..<index + 64]))
            index += 64
        }
        pending.append(contentsOf: input[index...])
    }

    /// Processes one 64-byte block.
    private mutating func compress(_ block: UnsafeBufferPointer<UInt8>) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
            for t in 0..<16 {
                w[t] = UInt32(block[t * 4]) << 24 | UInt32(block[t * 4 + 1]) << 16
                    | UInt32(block[t * 4 + 2]) << 8 | UInt32(block[t * 4 + 3])
            }
            for t in 16..<64 {
                let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for t in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choice &+ roundConstants[t] &+ w[t]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            state[0] &+= a
            state[1] &+= b
            state[2] &+= c
            state[3] &+= d
            state[4] &+= e
            state[5] &+= f
            state[6] &+= g
            state[7] &+= h
        }
    }
}

/// `bytes` as lowercase hex, two characters per byte.
package func hexEncoded(_ bytes: some Sequence<UInt8>) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var output: [UInt8] = []
    output.reserveCapacity(bytes.underestimatedCount * 2)
    for byte in bytes {
        output.append(digits[Int(byte >> 4)])
        output.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: output, as: UTF8.self)
}

@inline(__always)
private func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
    value >> count | value << (32 - count)
}

private let roundConstants: [UInt32] = [
    0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
    0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
    0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
    0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
    0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
    0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
    0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
    0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
]
