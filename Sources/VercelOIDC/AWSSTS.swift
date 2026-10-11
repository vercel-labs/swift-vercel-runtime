#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import VercelHTTP
import VercelRuntime

/// What to pass to STS `AssumeRoleWithWebIdentity`, and how to get the web identity token.
struct AssumeRoleParameters: Sendable, Equatable {
    var roleARN: String
    var region: String?
    var sessionName: String?
    var durationSeconds: Int?
    var audience: String?
    var jti: String?
}

extension OIDCClient {
    /// The Vercel OIDC token for `headers` (exchanged for `audience` when set), traded for AWS
    /// credentials with STS `AssumeRoleWithWebIdentity`.
    func awsCredentials(_ parameters: AssumeRoleParameters, headers: HTTPFields?) async throws -> AWSCredentials {
        let endpoint = try stsEndpoint(region: parameters.region)
        var webIdentityToken = try token(headers: headers)
        if let audience = parameters.audience {
            webIdentityToken = try await exchange(
                token: webIdentityToken, audience: audience, jti: parameters.jti, skipCache: false, headers: headers
            )
        }
        return try await assumeRoleWithWebIdentity(
            endpoint: endpoint,
            roleARN: parameters.roleARN,
            sessionName: parameters.sessionName ?? randomSessionName(),
            durationSeconds: parameters.durationSeconds,
            webIdentityToken: webIdentityToken,
            requestHeaders: headers
        )
    }

    /// The STS endpoint: regional for `region` (else `AWS_REGION`), global without one.
    func stsEndpoint(region: String?) throws(VercelOIDCError) -> String {
        guard let region = region.flatMap({ $0.isEmpty ? nil : $0 }) ?? environment("AWS_REGION") else {
            return "https://sts.amazonaws.com"
        }
        guard region.utf8.allSatisfy(isRegionByte), let first = region.utf8.first, first != UInt8(ascii: "-") else {
            throw .invalidRegion(region)
        }
        // China regions are under amazonaws.com.cn.
        let domain = region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
        return "https://sts.\(region).\(domain)"
    }

    /// Sends an unsigned `AssumeRoleWithWebIdentity` query API request and parses the XML response.
    func assumeRoleWithWebIdentity(
        endpoint: String,
        roleARN: String,
        sessionName: String,
        durationSeconds: Int?,
        webIdentityToken: String,
        requestHeaders: HTTPFields? = nil
    ) async throws -> AWSCredentials {
        var form = [
            (name: "Action", value: "AssumeRoleWithWebIdentity"),
            (name: "Version", value: "2011-06-15"),
            (name: "RoleArn", value: roleARN),
            (name: "RoleSessionName", value: sessionName),
            (name: "WebIdentityToken", value: webIdentityToken),
        ]
        if let durationSeconds {
            form.append((name: "DurationSeconds", value: String(durationSeconds)))
        }
        let response = try await send(
            .post,
            endpoint + "/",
            headerFields: [
                .contentType: "application/x-www-form-urlencoded; charset=utf-8",
                .userAgent: userAgent,
            ],
            body: Array(formURLEncoded(form).utf8),
            requestHeaders: requestHeaders
        )
        guard (200..<300).contains(response.status.code) else {
            let error = parseSTSError(response.body)
            throw VercelOIDCError.awsSTS(statusCode: response.status.code, code: error.code, message: error.message)
        }
        return try parseAssumeRoleResponse(response.body)
    }
}

/// `vercel-` and 16 random hex digits, a valid `RoleSessionName` (`[\w+=,.@-]{2,64}`).
func randomSessionName() -> String {
    let random = String(UInt64.random(in: .min ... .max), radix: 16)
    return "vercel-" + String(repeating: "0", count: 16 - random.utf8.count) + random
}

private func isRegionByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"): true
    default: false
    }
}

// MARK: - XML

/// The credentials in an `AssumeRoleWithWebIdentityResponse`.
func parseAssumeRoleResponse(_ body: [UInt8]) throws(VercelOIDCError) -> AWSCredentials {
    guard let credentials = xmlElement("Credentials", in: body[...]) else {
        throw .invalidSTSResponse(reason: "missing <Credentials>")
    }
    func field(_ name: String) throws(VercelOIDCError) -> String {
        guard let value = xmlText(name, in: credentials), !value.isEmpty else {
            throw .invalidSTSResponse(reason: "missing <\(name)>")
        }
        return value
    }
    let expirationText = try field("Expiration")
    guard let expiration = parseRFC3339(expirationText) else {
        throw .invalidSTSResponse(reason: "invalid <Expiration> \(expirationText)")
    }
    return AWSCredentials(
        accessKeyID: try field("AccessKeyId"),
        secretAccessKey: try field("SecretAccessKey"),
        sessionToken: try field("SessionToken"),
        expiration: expiration,
        assumedRoleARN: xmlElement("AssumedRoleUser", in: body[...]).flatMap { xmlText("Arn", in: $0) }
    )
}

/// The `<Code>` and `<Message>` of an STS `ErrorResponse`, if present.
func parseSTSError(_ body: [UInt8]) -> (code: String?, message: String?) {
    let scope = xmlElement("Error", in: body[...]) ?? body[...]
    return (xmlText("Code", in: scope).flatMap(nonEmpty), xmlText("Message", in: scope).flatMap(nonEmpty))
}

private func nonEmpty(_ string: String) -> String? {
    string.isEmpty ? nil : string
}

/// The text of the first `<name>` element in `xml`, unescaped and trimmed. Simple tag matching,
/// enough for AWS query API responses, which have no namespace prefixes on elements.
func xmlText(_ name: String, in xml: ArraySlice<UInt8>) -> String? {
    xmlElement(name, in: xml).map { xmlUnescaped($0) }
}

/// The raw content of the first `<name>` element in `xml` (empty for `<name/>`).
func xmlElement(_ name: String, in xml: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
    let open = Array("<\(name)".utf8)
    let close = Array("</\(name)".utf8)
    var searchStart = xml.startIndex
    while let start = firstIndex(of: open, in: xml[searchStart...]) {
        let afterName = start + open.count
        searchStart = afterName
        // `<name>`, `<name attr="...">` or `<name/>`, not `<nameSuffix>`.
        guard afterName < xml.endIndex else { return nil }
        let next = xml[afterName]
        guard next == UInt8(ascii: ">") || next == UInt8(ascii: "/") || isXMLSpace(next) else { continue }
        guard let tagEnd = xml[afterName...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
        if xml[tagEnd - 1] == UInt8(ascii: "/") {
            return xml[tagEnd..<tagEnd]
        }
        let contentStart = tagEnd + 1
        var closeSearch = contentStart
        while let end = firstIndex(of: close, in: xml[closeSearch...]) {
            var index = end + close.count
            while index < xml.endIndex, isXMLSpace(xml[index]) { index += 1 }
            if index < xml.endIndex, xml[index] == UInt8(ascii: ">") {
                return xml[contentStart..<end]
            }
            closeSearch = end + close.count
        }
        return nil
    }
    return nil
}

/// `text` with entity and character references (`&amp;`, `&#38;`, `&#x26;`) replaced, CDATA
/// sections unwrapped and surrounding whitespace removed. Unknown references are kept as is.
func xmlUnescaped(_ text: ArraySlice<UInt8>) -> String {
    let cdataOpen = Array("<![CDATA[".utf8)
    let cdataClose = Array("]]>".utf8)
    var output: [UInt8] = []
    output.reserveCapacity(text.count)
    var index = text.startIndex
    while index < text.endIndex {
        let byte = text[index]
        if byte == UInt8(ascii: "<"), text[index...].starts(with: cdataOpen) {
            let contentStart = index + cdataOpen.count
            let end = firstIndex(of: cdataClose, in: text[contentStart...]) ?? text.endIndex
            output.append(contentsOf: text[contentStart..<end])
            index = min(text.endIndex, end + cdataClose.count)
            continue
        }
        if byte == UInt8(ascii: "&"),
            let semicolon = text[index...].prefix(12).firstIndex(of: UInt8(ascii: ";")),
            let replacement = xmlEntity(text[(index + 1)..<semicolon])
        {
            output.append(contentsOf: replacement)
            index = semicolon + 1
            continue
        }
        output.append(byte)
        index += 1
    }
    let trimmed = output.drop(while: isXMLSpace).reversed().drop(while: isXMLSpace).reversed()
    return String(decoding: Array(trimmed), as: UTF8.self)
}

/// The UTF-8 bytes for the reference `&name;`, or `nil` if unknown.
private func xmlEntity(_ name: ArraySlice<UInt8>) -> [UInt8]? {
    switch String(decoding: name, as: UTF8.self) {
    case "amp": return [UInt8(ascii: "&")]
    case "lt": return [UInt8(ascii: "<")]
    case "gt": return [UInt8(ascii: ">")]
    case "quot": return [UInt8(ascii: "\"")]
    case "apos": return [UInt8(ascii: "'")]
    case let reference where reference.hasPrefix("#"):
        let digits = reference.dropFirst()
        let value = digits.first == "x" || digits.first == "X"
            ? UInt32(digits.dropFirst(), radix: 16)
            : UInt32(digits, radix: 10)
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return Array(String(Character(scalar)).utf8)
    default:
        return nil
    }
}

private func isXMLSpace(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
}

private func firstIndex(of needle: [UInt8], in haystack: ArraySlice<UInt8>) -> Int? {
    guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
    var index = haystack.startIndex
    let last = haystack.endIndex - needle.count
    while index <= last {
        if haystack[index] == needle[0], haystack[index..<(index + needle.count)].elementsEqual(needle) {
            return index
        }
        index += 1
    }
    return nil
}
