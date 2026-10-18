import Foundation

public enum SerializerError: Error, CustomStringConvertible {
    case invalidProperty(String)
    case missingType
    case unsupportedType(Int)
    case malformedItem(String)

    public var description: String {
        switch self {
        case .invalidProperty(let line): return "Invalid property format: \(line)"
        case .missingType: return "Missing required property: type_"
        case .unsupportedType(let t): return "Unsupported item type: \(t)"
        case .malformedItem(let m): return "Malformed item: \(m)"
        }
    }
}

/// Joplin's text item format (BaseItem.serialize / BaseItem.unserialize):
///
///     <title>
///
///     <body, notes only>
///
///     key: value
///     ...
///     type_: N
public enum Serializer {
    static let timeFields: Set<String> = ["created_time", "updated_time", "user_created_time", "user_updated_time"]

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func formatTime(_ ms: Int64) -> String {
        guard ms != 0 else { return "" }
        return isoFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    public static func parseTime(_ s: String) -> Int64 {
        guard !s.isEmpty else { return 0 }
        if let d = isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s) {
            return Int64((d.timeIntervalSince1970 * 1000).rounded())
        }
        return 0
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\\\\n")
            .replacingOccurrences(of: "\\r", with: "\\\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\\n", with: "\\n")
            .replacingOccurrences(of: "\\\r", with: "\\r")
    }

    static func formatValue(_ name: String, _ value: Any?) -> String {
        if timeFields.contains(name) {
            let ms: Int64
            switch value {
            case let v as Int64: ms = v
            case let v as Int: ms = Int64(v)
            case let v as Double: ms = Int64(v)
            case let v as String: ms = Int64(v) ?? 0
            default: ms = 0
            }
            return formatTime(ms)
        }
        let s: String
        switch value {
        case nil, is NSNull: s = ""
        case let v as Bool: s = v ? "1" : "0"
        case let v as Double where name == "latitude" || name == "longitude": s = String(format: "%.8f", v)
        case let v as Double where name == "altitude": s = String(format: "%.4f", v)
        case let v as Double: s = v == v.rounded() ? String(Int64(v)) : String(v)
        case let v?: s = "\(v)"
        }
        return name == "body" ? s : escape(s)
    }

    public static func serialize(type: ModelType, fields: [String: Any]) throws -> String {
        guard let defs = Schema.fields[type] else { throw SerializerError.unsupportedType(type.rawValue) }
        var parts: [String] = []
        parts.append((fields["title"] as? String) ?? "")
        if type == .note, let body = fields["body"] as? String, !body.isEmpty {
            parts.append(body)
        }
        var props: [String] = []
        for def in defs where def.name != "title" && def.name != "body" {
            props.append("\(def.name): \(formatValue(def.name, fields[def.name] ?? def.defaultSQLValue))")
        }
        props.append("type_: \(type.rawValue)")
        parts.append(props.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    /// Parses a serialized item. Unknown properties are dropped, values are converted to SQL types.
    public static func unserialize(_ content: String) throws -> (type: ModelType, fields: [String: Any]) {
        let lines = content.components(separatedBy: "\n")
        var raw: [String: String] = [:]
        var bodyLines: [String] = []

        var i = lines.count - 1
        while i >= 0 {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                bodyLines = Array(lines[0..<i])
                break
            }
            guard let colon = line.firstIndex(of: ":") else { throw SerializerError.invalidProperty(line) }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            raw[key] = value
            i -= 1
        }

        guard let typeString = raw["type_"], let typeInt = Int(typeString) else { throw SerializerError.missingType }
        guard let type = ModelType(rawValue: typeInt), let defs = Schema.fields[type] else {
            throw SerializerError.unsupportedType(typeInt)
        }

        if !bodyLines.isEmpty {
            raw["title"] = bodyLines[0]
            if type == .note {
                raw["body"] = bodyLines.count > 2 ? bodyLines[2...].joined(separator: "\n") : ""
            }
        }

        if let id = raw["id"], !id.isEmpty, id.count != 32 || !id.allSatisfy(\.isHexDigit) {
            throw SerializerError.malformedItem("invalid id \(id)")
        }
        if let ext = raw["file_extension"], ext.contains("/") || ext.contains("\\") || ext.contains("..") {
            throw SerializerError.malformedItem("invalid file extension \(ext)")
        }

        var fields: [String: Any] = [:]
        for def in defs {
            guard let value = raw[def.name] else { continue }
            if timeFields.contains(def.name) {
                fields[def.name] = parseTime(value)
                continue
            }
            switch def.type {
            case .int: fields[def.name] = Int64(value) ?? Int64(Double(value) ?? 0)
            case .numeric: fields[def.name] = Double(value) ?? 0
            case .text: fields[def.name] = def.name == "body" ? value : unescape(value)
            }
        }
        return (type, fields)
    }
}
