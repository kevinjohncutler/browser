import CoreFoundation
import Foundation

indirect enum PreferenceValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([PreferenceValue]), object([String: PreferenceValue])

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() {
            self = .null
        } else if let value = try? box.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? box.decode(Double.self) {
            self = .number(value)
        } else if let value = try? box.decode(String.self) {
            self = .string(value)
        } else if let value = try? box.decode([PreferenceValue].self) {
            self = .array(value)
        } else {
            self = try .object(box.decode([String: PreferenceValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .null: try box.encodeNil()
        case let .bool(value): try box.encode(value)
        case let .number(value): try box.encode(value)
        case let .string(value): try box.encode(value)
        case let .array(value): try box.encode(value)
        case let .object(value): try box.encode(value)
        }
    }

    static func from(_ object: Any) throws -> PreferenceValue {
        try JSONDecoder().decode(
            Self.self,
            from: JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed)
        )
    }

    var schemaType: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case let .number(number): number.rounded() == number ? "integer" : "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .number(value): return value
        case let .string(value): return value
        case let .array(value): return value.map(\.foundation)
        case let .object(value): return value.mapValues(\.foundation)
        }
    }

    var text: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    var numeric: Double? {
        if case let .number(value) = self {
            return value
        }
        return nil
    }

    var boolean: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }

    var dictionary: [String: PreferenceValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    var items: [PreferenceValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }
}

struct PreferenceDefinition: Codable, Identifiable {
    var id: String
    let title: String
    let description: String
    let category: String
    let scope: String
    let apply: String
    var defaultsKey: String?
    let storage: String?
    let path: [String]?
    let source: String?
    let schema: [String: PreferenceValue]
    var defaultValue: PreferenceValue {
        schema["default"] ?? .null
    }

    func instantiated(spaceID: String) -> Self {
        var result = self
        result.id = id.replacingOccurrences(of: "{spaceId}", with: spaceID)
        result.defaultsKey = defaultsKey?.replacingOccurrences(of: "{spaceId}", with: spaceID)
        return result
    }
}

struct PreferenceCatalog: Decodable {
    let version: Int
    let settings: [PreferenceDefinition]

    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "settings-schema", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func definition(_ key: String) throws -> PreferenceDefinition {
        if let match = settings.first(where: { $0.id == key }) {
            return match
        }
        let parts = key.split(separator: ".")
        if parts.count >= 3, parts[0] == "space", UUID(uuidString: String(parts[1])) != nil,
           let match = settings
           .first(where: { $0.scope == "space" && $0.instantiated(spaceID: String(parts[1])).id == key })
        {
            return match.instantiated(spaceID: String(parts[1]))
        }
        throw PreferenceError("Unknown setting: \(key).")
    }

    static func canonicalKey(_ key: String) -> String {
        var parts = key.split(separator: ".").map(String.init)
        if parts.count >= 3, parts[0] == "space", let id = UUID(uuidString: parts[1]) {
            parts[1] = id.uuidString
        }
        return parts.joined(separator: ".")
    }

    func canonicalPatch(_ patch: [String: PreferenceValue]) throws -> [String: PreferenceValue] {
        try validate(patch)
        var result: [String: PreferenceValue] = [:]
        for (key, value) in patch {
            let canonical = Self.canonicalKey(key)
            guard result[canonical] == nil else { throw PreferenceError("Duplicate space setting aliases.") }
            result[canonical] = value
        }
        return result
    }

    func validate(_ patch: [String: PreferenceValue]) throws {
        guard patch.count <= 1000 else { throw PreferenceError("Too many settings.") }
        for (key, value) in patch {
            try Self.validate(value, schema: definition(key).schema, label: key)
        }
    }

    static func validate(_ value: PreferenceValue, schema: [String: PreferenceValue], label: String) throws {
        let allowed = schema["type"]?.items?.compactMap(\.text) ?? [schema["type"]?.text ?? ""]
        guard allowed.contains(value.schemaType) || (value.schemaType == "integer" && allowed.contains("number")) else {
            throw PreferenceError("\(label): expected \(allowed.joined(separator: ", ")).")
        }
        if let choices = schema["enum"]?.items,
           !choices.contains(value)
        {
            throw PreferenceError("\(label): invalid choice.")
        }
        try validateNumber(value, schema: schema, label: label)
        try validateText(value, schema: schema, label: label)
        try validateArray(value, schema: schema, label: label)
        try validateObject(value, schema: schema, label: label)
    }

    private static func validateNumber(
        _ value: PreferenceValue,
        schema: [String: PreferenceValue],
        label: String
    ) throws {
        guard let number = value.numeric else { return }
        guard number.isFinite, number >= (schema["minimum"]?.numeric ?? -.infinity),
              number <= (schema["maximum"]?.numeric ?? .infinity)
        else { throw PreferenceError("\(label): number is outside the allowed range.") }
    }

    private static func validateText(
        _ value: PreferenceValue,
        schema: [String: PreferenceValue],
        label: String
    ) throws {
        guard let text = value.text else { return }
        if schema["contentEncoding"]?.text == "base64",
           Data(base64Encoded: text) == nil
        {
            throw PreferenceError("\(label): invalid base64 data.")
        }
        guard text.unicodeScalars.count >= Int(schema["minLength"]?.numeric ?? 0),
              text.unicodeScalars.count <= Int(schema["maxLength"]?.numeric ?? 200_000),
              schema["pattern"]?.text.map({ text.range(of: $0, options: .regularExpression) != nil }) ?? true
        else { throw PreferenceError("\(label): invalid text.") }
    }

    private static func validateArray(
        _ value: PreferenceValue,
        schema: [String: PreferenceValue],
        label: String
    ) throws {
        guard let array = value.items else { return }
        guard array.count <= Int(schema["maxItems"]?.numeric ?? 1000), let itemSchema = schema["items"]?.dictionary
        else { throw PreferenceError("\(label): invalid list.") }
        if schema["uniqueItemIDs"]?.boolean == true {
            let ids = array.compactMap { $0.dictionary?["id"]?.text }
            guard Set(ids).count == array.count else { throw PreferenceError("\(label): item IDs must be unique.") }
        }
        let forbidden = schema["forbiddenItemIDs"]?.items?.compactMap(\.text) ?? []
        guard !array.contains(where: { forbidden.contains($0.dictionary?["id"]?.text ?? "") })
        else { throw PreferenceError("\(label): reserved item ID.") }
        for item in array {
            try validate(item, schema: itemSchema, label: label)
        }
    }

    private static func validateObject(
        _ value: PreferenceValue,
        schema: [String: PreferenceValue],
        label: String
    ) throws {
        guard let object = value.dictionary else { return }
        guard object.count <= Int(schema["maxProperties"]?.numeric ?? 1000),
              (schema["required"]?.items?.compactMap(\.text) ?? []).allSatisfy({ object[$0] != nil })
        else { throw PreferenceError("\(label): missing fields or too many properties.") }
        for (key, child) in object {
            if let names = schema["propertyNames"]?.dictionary {
                try validate(
                    .string(key),
                    schema: names,
                    label: label
                )
            }
            if let field = schema["mapKeyField"]?.text,
               child
               .dictionary?[field] !=
               .string(key)
            {
                throw PreferenceError("\(label): map key does not match item field.")
            }
            let childSchema = schema["properties"]?
                .dictionary?[key] ?? schema["additionalProperties"] ?? .bool(false)
            if let dictionary = childSchema.dictionary {
                try validate(
                    child,
                    schema: dictionary,
                    label: "\(label).\(key)"
                )
            } else if childSchema.boolean != true {
                throw PreferenceError("\(label): unknown property \(key).")
            }
        }
    }
}

struct PreferenceError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) {
        errorDescription = message
    }
}
