#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Parses an RFC 3339 timestamp such as `2026-10-11T17:00:00.123Z` or
/// `2026-10-11T19:00:00+02:00`, truncated to milliseconds like the Python runtime.
///
/// Accepts `T`, `t` or a space between date and time, any number of fractional digits, and `Z`,
/// `z` or a `±HH:MM` offset. Returns `nil` for anything else, including out-of-range fields.
/// Hand-written so it needs nothing beyond `Date`. Shared with the feature modules (for example
/// the `Expiration` in AWS STS responses, such as `2026-10-11T18:00:00Z`).
package func parseRFC3339(_ string: String) -> Date? {
    var parser = RFC3339Parser(bytes: Array(string.utf8))
    return parser.parse()
}

private struct RFC3339Parser {
    let bytes: [UInt8]
    var index = 0

    mutating func parse() -> Date? {
        guard let year = number(digits: 4), take("-"),
            let month = number(digits: 2), take("-"),
            let day = number(digits: 2), take("T") || take("t") || take(" "),
            let hour = number(digits: 2), take(":"),
            let minute = number(digits: 2), take(":"),
            let second = number(digits: 2)
        else { return nil }

        var milliseconds = 0
        if take(".") {
            var digits = 0
            while let digit = digit() {
                if digits < 3 { milliseconds = milliseconds * 10 + digit }
                digits += 1
            }
            guard digits > 0 else { return nil }
            for _ in digits..<max(digits, 3) { milliseconds *= 10 }
        }

        let offsetSeconds: Int
        if take("Z") || take("z") {
            offsetSeconds = 0
        } else if let sign = take("+") ? 1 : take("-") ? -1 : nil,
            let offsetHours = number(digits: 2), take(":"), let offsetMinutes = number(digits: 2),
            offsetHours <= 23, offsetMinutes <= 59
        {
            offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
        } else {
            return nil
        }

        // RFC 3339 allows a leap second (60), but the Python runtime's `datetime` rejects it, so
        // it is rejected here too.
        guard index == bytes.count,
            (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day),
            hour <= 23, minute <= 59, second <= 59
        else { return nil }

        let seconds = daysSinceUnixEpoch(year: year, month: month, day: day) * 86_400
            + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds * 1000 + milliseconds) / 1000)
    }

    private mutating func take(_ character: Unicode.Scalar) -> Bool {
        guard index < bytes.count, bytes[index] == UInt8(ascii: character) else { return false }
        index += 1
        return true
    }

    private mutating func digit() -> Int? {
        guard index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else { return nil }
        defer { index += 1 }
        return Int(bytes[index] - UInt8(ascii: "0"))
    }

    private mutating func number(digits: Int) -> Int? {
        var value = 0
        for _ in 0..<digits {
            guard let digit = digit() else { return nil }
            value = value * 10 + digit
        }
        return value
    }
}

private func daysIn(month: Int, year: Int) -> Int {
    switch month {
    case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
}

/// Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
private func daysSinceUnixEpoch(year: Int, month: Int, day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}
