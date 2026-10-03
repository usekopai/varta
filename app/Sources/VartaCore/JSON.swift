import Foundation

/// JSON with ordered objects. Jev sees options in the order they are sent, so questions are built
/// with this rather than dictionaries (Foundation's encoder does not keep key order).
public indirect enum JSON: Equatable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public subscript(key: String) -> JSON? {
        if case let .object(pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    public var string: String? { if case let .string(s) = self { return s }; return nil }
    public var double: Double? { if case let .number(n) = self { return n }; return nil }
    public var array: [JSON]? { if case let .array(a) = self { return a }; return nil }
    public var object: [(String, JSON)]? { if case let .object(o) = self { return o }; return nil }

    /// Compact UTF-8 serialization.
    public var description: String {
        var out = ""
        write(&out)
        return out
    }

    public var data: Data { Data(description.utf8) }

    private func write(_ out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .number(n):
            if n.rounded() == n, abs(n) < 1e15 { out += String(Int64(n)) } else { out += String(n) }
        case let .string(s): JSON.escape(s, into: &out)
        case let .array(items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(&out)
            }
            out += "]"
        case let .object(pairs):
            out += "{"
            for (i, (k, v)) in pairs.enumerated() {
                if i > 0 { out += "," }
                JSON.escape(k, into: &out)
                out += ":"
                v.write(&out)
            }
            out += "}"
        }
    }

    private static func escape(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    /// From JSONSerialization output. Object key order is not preserved there, which is fine for
    /// responses: only requests need a stable order.
    public init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSON(any: $0) })
        case let d as [String: Any]: self = .object(d.keys.sorted().map { ($0, JSON(any: d[$0])) })
        default: self = .null
        }
    }

    public static func parse(_ data: Data) throws -> JSON {
        JSON(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

/// Build an ordered object: `obj(("type", "choice"), ("instructions", ...))`.
public func obj(_ pairs: (String, JSON)...) -> JSON { .object(pairs) }
