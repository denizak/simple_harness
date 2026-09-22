import Foundation

// ---------------------------------------------------------------------------
// JSONValue — a tiny dynamic JSON type.
//
// Why do we need this? Tool *input schemas* and tool *arguments* are arbitrary
// JSON objects ({"path": "x.swift", "limit": 10}). Swift's Codable wants a
// fixed schema, but tool arguments are decided by the model at runtime, so we
// need a value type that can hold "any JSON".
//
// This is the single most common building block in agent harnesses — pi,
// LangChain, and Claude Code all have an equivalent.
// ---------------------------------------------------------------------------

indirect enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Convenience accessors for reading tool arguments.
    var stringValue: String? { if case .string(let string) = self { return string }; return nil }
    var intValue: Int? {
        if case .number(let number) = self, number == number.rounded(), abs(number) < 1e15 {
            return Int(number)
        }
        return nil
    }
    var boolValue: Bool? { if case .bool(let bool) = self { return bool }; return nil }
    var doubleValue: Double? { if case .number(let number) = self { return number }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let object) = self { return object }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let array) = self { return array }; return nil }

    func string(forKey key: String) -> String? { objectValue?[key]?.stringValue }
    func int(forKey key: String) -> Int? { objectValue?[key]?.intValue }
    func bool(forKey key: String) -> Bool? { objectValue?[key]?.boolValue }

    // MARK: Codable — delegates to JSONSerialization-free manual mapping.

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let boolean = try? container.decode(Bool.self) { self = .bool(boolean) }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else if let string = try? container.decode(String.self) { self = .string(string) }
        else if let array = try? container.decode([JSONValue].self) { self = .array(array) }
        else if let object = try? container.decode([String: JSONValue].self) { self = .object(object) }
        else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Not valid JSON")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }

    /// Build from a JSON string (used to parse model-generated tool arguments).
    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        // JSONSerialization gives ObjC types (NSDictionary/NSArray/NSNumber);
        // Codable expects Swift types. Bridge by round-tripping through a
        // wrapper struct: wrap the raw object as {"value": <raw>}, re-encode,
        // then let JSONDecoder decode it as Wrapper — the JSONValue Codable
        // conformance does the actual ObjC→Swift mapping for us.
        struct Wrapper: Codable { let value: JSONValue }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let wrapped = try? JSONSerialization.data(withJSONObject: ["value": object]),
              let wrapper = try? JSONDecoder().decode(Wrapper.self, from: wrapped) else { return nil }
        return wrapper.value
    }
}