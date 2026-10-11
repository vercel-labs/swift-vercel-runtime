#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A JSON value stored in Global Config, for reading items without declaring a `Decodable` type.
///
/// ```swift
/// let config = try GlobalConfig.default
/// if let banner = try await config.get("banner"), banner["enabled"]?.boolValue == true {
///     print(banner["text"]?.stringValue ?? "")
/// }
/// ```
///
/// Numbers are `Double`s, like in JavaScript. Use ``decode(as:)`` to turn a value into a
/// `Decodable` type.
public enum GlobalConfigValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([GlobalConfigValue])
    case object([String: GlobalConfigValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([GlobalConfigValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: GlobalConfigValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            // Integral values encode without a fraction so they decode as integers again.
            if let integer = Int64(exactly: value), abs(integer) <= Self.maxSafeInteger {
                try container.encode(integer)
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    /// 2^53 - 1, the largest integer a `Double` (and a JavaScript number) represents exactly.
    private static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    /// Decodes the value as `type`.
    ///
    /// ```swift
    /// struct Banner: Decodable { var enabled: Bool; var text: String }
    /// let banner = try value.decode(as: Banner.self)
    /// ```
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        if let value = self as? T {
            return value
        }
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    /// Whether the value is `null`.
    public var isNull: Bool {
        if case .null = self { true } else { false }
    }

    /// The value when it is a boolean.
    public var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    /// The value when it is a number.
    public var doubleValue: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    /// The value when it is a number without a fractional part that fits in `Int`.
    public var intValue: Int? {
        if case .number(let value) = self { Int(exactly: value) } else { nil }
    }

    /// The value when it is a string.
    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    /// The elements when the value is an array.
    public var arrayValue: [GlobalConfigValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    /// The members when the value is an object.
    public var objectValue: [String: GlobalConfigValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    /// The member named `key` when the value is an object.
    public subscript(key: String) -> GlobalConfigValue? {
        objectValue?[key]
    }

    /// The element at `index` when the value is an array and `index` is in bounds.
    public subscript(index: Int) -> GlobalConfigValue? {
        guard case .array(let elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }
}

extension GlobalConfigValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }

    public init(floatLiteral value: Double) {
        self = .number(value)
    }

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(arrayLiteral elements: GlobalConfigValue...) {
        self = .array(elements)
    }

    public init(dictionaryLiteral elements: (String, GlobalConfigValue)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}
