import Testing
@testable import VercelHTTP

/// Test vectors from NIST (FIPS 180-4 examples and the SHA-256 short and long message tests).
@Suite struct SHA256Tests {
    @Test(arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        // 448 bits: padding needs a second block.
        (
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        ),
        // 896 bits.
        (
            "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
            "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
        ),
        ("The quick brown fox jumps over the lazy dog", "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"),
        ("héllo 🌍", "cbbcee01a3fc5f1c0db23e02be25316adf28ede876031fdbabe5f4fabe47ed7f"),
    ])
    func knownVectors(message: String, digest: String) {
        #expect(SHA256.hexDigest(message) == digest)
        #expect(SHA256.hexDigest(Array(message.utf8)) == digest)
    }

    @Test func oneMillionAs() {
        let message = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(SHA256.hexDigest(message) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func incrementalUpdatesMatchOneShot() {
        let message = Array("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu".utf8)
        let expected = SHA256.hash(message)
        // Every split point, including inside and across 64-byte blocks.
        for split in 0...message.count {
            var hasher = SHA256()
            hasher.update(message[..<split])
            hasher.update(message[split...].lazy.map { $0 })  // a non-contiguous sequence
            #expect(hasher.finalize() == expected, "split at \(split)")
        }
        // A million bytes in uneven chunks.
        var hasher = SHA256()
        var remaining = 1_000_000
        var chunk = 1
        while remaining > 0 {
            let count = min(chunk, remaining)
            hasher.update([UInt8](repeating: UInt8(ascii: "a"), count: count))
            remaining -= count
            chunk = chunk % 997 + 13
        }
        #expect(hexEncoded(hasher.finalize()) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func finalizeDoesNotConsumeTheHasher() {
        var hasher = SHA256()
        hasher.update("ab")
        _ = hasher.finalize()
        hasher.update("c")
        #expect(hexEncoded(hasher.finalize()) == SHA256.hexDigest("abc"))
        #expect(hasher.finalize().count == SHA256.digestSize)
    }

    @Test func hexEncoding() {
        #expect(hexEncoded([]) == "")
        #expect(hexEncoded([0x00, 0x0f, 0xa0, 0xff]) == "000fa0ff")
    }
}
