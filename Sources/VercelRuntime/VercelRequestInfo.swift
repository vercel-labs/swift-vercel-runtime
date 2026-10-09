public import HTTPTypes

/// Where a request came from, from the headers Vercel adds to every request.
///
/// Matches `geolocation()` from `@vercel/functions`.
public struct VercelGeolocation: Sendable, Hashable, Codable {
    /// City name, for example `San Francisco`.
    public var city: String?
    /// ISO 3166-1 alpha-2 country code, for example `US`.
    public var country: String?
    /// Flag emoji for ``country``.
    public var flag: String?
    /// ISO 3166-2 region code within the country, for example `CA`.
    public var countryRegion: String?
    /// Vercel region that handled the request, for example `iad1` (`dev1` locally).
    public var region: String?
    public var latitude: String?
    public var longitude: String?
    public var postalCode: String?

    public init(
        city: String? = nil,
        country: String? = nil,
        flag: String? = nil,
        countryRegion: String? = nil,
        region: String? = nil,
        latitude: String? = nil,
        longitude: String? = nil,
        postalCode: String? = nil
    ) {
        self.city = city
        self.country = country
        self.flag = flag
        self.countryRegion = countryRegion
        self.region = region
        self.latitude = latitude
        self.longitude = longitude
        self.postalCode = postalCode
    }
}

/// Vercel-specific information about a request.
///
/// Available as `request.vercel` in the framework adapters, or `headers.vercel` on any
/// `HTTPFields`.
public struct VercelRequestInfo: Sendable {
    public let headers: HTTPFields

    public init(headers: HTTPFields) {
        self.headers = headers
    }

    /// The Vercel request id (`x-vercel-id`), as shown in Vercel's logs.
    public var id: String? {
        headers[.vercelID]
    }

    /// The client IP address (`x-real-ip`).
    public var ipAddress: String? {
        headers[.realIP]
    }

    /// Where the request came from.
    public var geolocation: VercelGeolocation {
        let country = headers[.vercelIPCountry]
        return VercelGeolocation(
            // The city may be percent-encoded to support multi-byte characters.
            city: headers[.vercelIPCity].map(percentDecoded),
            country: country,
            flag: country.flatMap(flagEmoji),
            countryRegion: headers[.vercelIPCountryRegion],
            region: headers[.vercelID].map { String($0.split(separator: ":", omittingEmptySubsequences: false)[0]) } ?? "dev1",
            latitude: headers[.vercelIPLatitude],
            longitude: headers[.vercelIPLongitude],
            postalCode: headers[.vercelIPPostalCode]
        )
    }

    /// The Vercel OIDC token for this request, to authenticate with cloud providers. Falls back
    /// to the `VERCEL_OIDC_TOKEN` environment variable (set by `vercel env pull` locally).
    public var oidcToken: String? {
        headers[.vercelOIDCToken] ?? VercelEnvironment.current.oidcToken
    }
}

extension HTTPFields {
    /// Vercel-specific information about the request these headers belong to.
    public var vercel: VercelRequestInfo {
        VercelRequestInfo(headers: self)
    }
}

extension HTTPField.Name {
    static let vercelID = Self("x-vercel-id")!
    static let realIP = Self("x-real-ip")!
    static let vercelIPCity = Self("x-vercel-ip-city")!
    static let vercelIPCountry = Self("x-vercel-ip-country")!
    static let vercelIPCountryRegion = Self("x-vercel-ip-country-region")!
    static let vercelIPLatitude = Self("x-vercel-ip-latitude")!
    static let vercelIPLongitude = Self("x-vercel-ip-longitude")!
    static let vercelIPPostalCode = Self("x-vercel-ip-postal-code")!
    static let vercelOIDCToken = Self(VercelHeader.oidcToken)!
}

/// Regional indicator symbols for a two-letter uppercase country code.
func flagEmoji(_ countryCode: String) -> String? {
    let scalars = Array(countryCode.unicodeScalars)
    guard scalars.count == 2, scalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
    var flag = String.UnicodeScalarView()
    for scalar in scalars {
        guard let indicator = Unicode.Scalar(127_397 + scalar.value) else { return nil }
        flag.append(indicator)
    }
    return String(flag)
}

/// Decodes `%XX` escapes as UTF-8, like JavaScript's `decodeURIComponent`. Returns the input
/// unchanged if it is malformed.
func percentDecoded(_ value: String) -> String {
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
