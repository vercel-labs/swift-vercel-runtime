import HTTPTypes
import Testing
@testable import VercelHTTP

@Suite struct URLEncodingTests {
    @Test func percentEncodingKeepsOnlyUnreservedCharacters() {
        #expect(percentEncoded("") == "")
        #expect(percentEncoded("AZaz09-._~") == "AZaz09-._~")
        #expect(percentEncoded("a b/c?d#e&f=g+h%i") == "a%20b%2Fc%3Fd%23e%26f%3Dg%2Bh%25i")
        #expect(percentEncoded("!*'();:@$,[]") == "%21%2A%27%28%29%3B%3A%40%24%2C%5B%5D")
        #expect(percentEncoded("São Paulo") == "S%C3%A3o%20Paulo")
        #expect(percentEncoded("🌍") == "%F0%9F%8C%8D")
    }

    @Test func percentEncodingRoundTripsThroughDecoding() {
        let value = "rate-limit/ü ✓?x=1"
        let encoded = percentEncoded(value)
        // The result is safe in a path segment or query value: only unreserved bytes and escapes.
        #expect(encoded.utf8.allSatisfy { $0 < 0x80 && $0 != UInt8(ascii: "/") && $0 != UInt8(ascii: "?") && $0 != UInt8(ascii: " ") })
        #expect(decode(encoded) == value)
    }

    @Test func queryStrings() {
        #expect(queryString([]) == "")
        #expect(queryString([("version", "1"), ("key", "a b"), ("key", "c&d")]) == "version=1&key=a%20b&key=c%26d")
        #expect(queryString([("ä", "=")]) == "%C3%A4=%3D")
    }

    @Test func formURLEncoding() {
        #expect(formURLEncoded([]) == "")
        #expect(
            formURLEncoded([
                ("Action", "AssumeRoleWithWebIdentity"),
                ("RoleArn", "arn:aws:iam::123456789012:role/my-role"),
                ("RoleSessionName", "a b~c*d"),
                ("WebIdentityToken", "eyJ.a+b/c="),
            ])
                == "Action=AssumeRoleWithWebIdentity&RoleArn=arn%3Aaws%3Aiam%3A%3A123456789012%3Arole%2Fmy-role&RoleSessionName=a+b%7Ec*d&WebIdentityToken=eyJ.a%2Bb%2Fc%3D"
        )
        #expect(formURLEncoded([("é", "\n")]) == "%C3%A9=%0A")
    }

    /// Expected values from Node's `encodeURIComponent`.
    @Test func uriComponentEncodingMatchesJavaScript() {
        #expect(uriComponentEncoded("!*()'~-._ a/é") == "!*()'~-._%20a%2F%C3%A9")
        #expect(uriComponentEncoded("AZaz09") == "AZaz09")
        #expect(uriComponentEncoded("?#&=+$,;:@[]%") == "%3F%23%26%3D%2B%24%2C%3B%3A%40%5B%5D%25")
        #expect(uriComponentEncoded("🚀") == "%F0%9F%9A%80")
    }

    @Test func redactsUserInfo() {
        #expect(redactingUserInfo("https://user:secret@example.com/a?b=c@d") == "https://<redacted>@example.com/a?b=c@d")
        #expect(redactingUserInfo("https://a@b@example.com") == "https://<redacted>@example.com")
        #expect(redactingUserInfo("https://example.com/a@b") == "https://example.com/a@b")
        #expect(redactingUserInfo("https://example.com?x=@") == "https://example.com?x=@")
        #expect(redactingUserInfo("not a url") == "not a url")
    }

    private func decode(_ value: String) -> String {
        var bytes: [UInt8] = []
        var iterator = value.utf8.makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%"), let high = iterator.next(), let low = iterator.next() {
                bytes.append(UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) ?? 0)
            } else {
                bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
