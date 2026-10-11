#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import VercelRuntime

/// Dates in cached values, written and read the way Node writes them, so Swift and Node functions
/// can share entries that contain dates.
///
/// `JSON.stringify` turns a `Date` into `Date.prototype.toJSON()`: ISO 8601 in UTC with
/// milliseconds, `2026-10-11T17:00:00.123Z`. Reading accepts that and other RFC 3339 timestamps,
/// with or without fractional seconds and with `Z` or an offset.
enum JavaScriptDate {
    /// `date` as JavaScript's `Date.prototype.toISOString()` writes it, truncated to milliseconds:
    /// `2026-10-11T17:00:00.123Z`. Years outside 0...9999 use the expanded form, `+010000-…`.
    /// `nil` outside JavaScript's date range (±8.64e15 ms around 1970).
    static func string(from date: Date) -> String? {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded(.down)
        guard milliseconds.isFinite, abs(milliseconds) <= 8.64e15 else { return nil }
        let total = Int64(milliseconds)
        let millisecondsPerDay: Int64 = 86_400_000
        var days = total / millisecondsPerDay
        var timeOfDay = total % millisecondsPerDay
        if timeOfDay < 0 {
            days -= 1
            timeOfDay += millisecondsPerDay
        }
        let (year, month, day) = civilDate(daysSince1970: days)
        let yearText: String
        if (0...9999).contains(year) {
            yearText = padded(year, 4)
        } else {
            yearText = (year < 0 ? "-" : "+") + padded(abs(year), 6)
        }
        return "\(yearText)-\(padded(month, 2))-\(padded(day, 2))T"
            + "\(padded(timeOfDay / 3_600_000, 2)):\(padded(timeOfDay / 60_000 % 60, 2)):\(padded(timeOfDay / 1000 % 60, 2))"
            + ".\(padded(timeOfDay % 1000, 3))Z"
    }

    /// The date in an RFC 3339 timestamp such as `2026-10-11T17:00:00.123Z` or
    /// `2026-10-11T19:00:00+02:00`, truncated to milliseconds. `nil` for anything else.
    static func date(from string: String) -> Date? {
        parseRFC3339(string)
    }

    static let encodingStrategy = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
        guard let text = string(from: date) else {
            throw EncodingError.invalidValue(
                date,
                EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Date is outside JavaScript's date range")
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    static let decodingStrategy = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = date(from: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO 8601 date like 2026-10-11T17:00:00.123Z, found \(text)"
            )
        }
        return date
    }
}

/// Year, month and day of the proleptic Gregorian calendar for days since 1970-01-01 (Howard
/// Hinnant's `civil_from_days`).
private func civilDate(daysSince1970 days: Int64) -> (year: Int64, month: Int64, day: Int64) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let dayOfEra = z - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    return (year, month, day)
}

private func padded(_ value: Int64, _ width: Int) -> String {
    let digits = String(value)
    return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
}
