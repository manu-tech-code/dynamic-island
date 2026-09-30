import Foundation

/// A JSON tree, used to merge a stored settings group over its defaults so a
/// file missing newer fields (or holding a bad value) keeps everything else.
enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    /// Overlays `other` onto `self`, key by key for objects.
    func merged(with other: JSONValue) -> JSONValue {
        if case .object(var base) = self, case .object(let top) = other {
            for (k, v) in top { base[k] = base[k].map { $0.merged(with: v) } ?? v }
            return .object(base)
        }
        return other
    }
}

extension KeyedDecodingContainer {
    /// Decodes a settings group, filling missing fields from `fallback`. A
    /// group that still fails (a bad value) falls back as a whole.
    func tolerant<T: Codable>(_ key: Key, _ fallback: T) -> T {
        guard let stored = try? decodeIfPresent(JSONValue.self, forKey: key),
              let defaultsData = try? JSONEncoder().encode(fallback),
              let defaults = try? JSONDecoder().decode(JSONValue.self, from: defaultsData),
              let mergedData = try? JSONEncoder().encode(defaults.merged(with: stored)),
              let value = try? JSONDecoder().decode(T.self, from: mergedData) else { return fallback }
        return value
    }
}
