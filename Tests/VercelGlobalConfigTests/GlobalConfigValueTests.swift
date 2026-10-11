#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
@testable import VercelGlobalConfig

@Suite struct GlobalConfigValueTests {
    @Test func decodesEveryKind() throws {
        let json = #"[null,true,false,0,1,-2.5,"s",[1],{"k":"v"}]"#
        let value = try JSONDecoder().decode(GlobalConfigValue.self, from: Data(json.utf8))
        #expect(value == [.null, true, false, 0, 1, -2.5, "s", [1], ["k": "v"]])
    }

    @Test func decodesFragments() throws {
        #expect(try JSONDecoder().decode(GlobalConfigValue.self, from: Data(#""text""#.utf8)) == "text")
        #expect(try JSONDecoder().decode(GlobalConfigValue.self, from: Data("1".utf8)) == 1)
        #expect(try JSONDecoder().decode(GlobalConfigValue.self, from: Data("true".utf8)) == true)
    }

    @Test func integralNumbersEncodeWithoutFraction() throws {
        let data = try JSONEncoder().encode([GlobalConfigValue.number(3), .number(1.5), .number(1e300)])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("[3,1.5,"))
    }

    @Test func decodesAsTypes() throws {
        struct Rule: Decodable, Equatable {
            var from: String
            var to: String
            var permanent: Bool
            var weight: Int
        }
        let value: GlobalConfigValue = ["from": "/a", "to": "/b", "permanent": true, "weight": 2]
        #expect(try value.decode(as: Rule.self) == Rule(from: "/a", to: "/b", permanent: true, weight: 2))
        #expect(try value.decode(as: GlobalConfigValue.self) == value)
        #expect(throws: DecodingError.self) { try GlobalConfigValue.number(1.5).decode(as: Int.self) }
    }

    @Test func accessors() {
        let value: GlobalConfigValue = ["n": 2, "d": 2.5, "s": "x", "b": false, "a": [1, 2], "z": .null]
        #expect(value["n"]?.intValue == 2)
        #expect(value["d"]?.intValue == nil)
        #expect(value["d"]?.doubleValue == 2.5)
        #expect(value["s"]?.stringValue == "x")
        #expect(value["b"]?.boolValue == false)
        #expect(value["a"]?[1] == 2)
        #expect(value["a"]?[2] == nil)
        #expect(value["a"]?.arrayValue?.count == 2)
        #expect(value["z"]?.isNull == true)
        #expect(value["missing"] == nil)
        #expect(value.objectValue?.count == 6)
        #expect(value["s"]?["key"] == nil)
    }
}
