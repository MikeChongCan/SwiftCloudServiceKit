import Foundation

public struct AnyCodable: Codable, Hashable, Sendable {
    private enum Storage: Codable, Hashable, Sendable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case dictionary([String: AnyCodable])
        case array([AnyCodable])
        case int64(Int64)
    }
    
    private let storage: Storage
    
    public var value: Any {
        switch storage {
        case .string(let val): return val
        case .int(let val): return val
        case .double(let val): return val
        case .bool(let val): return val
        case .dictionary(let val): return val.mapValues { $0.value }
        case .array(let val): return val.map { $0.value }
        case .int64(let val): return val
        }
    }
    
    public init(_ value: Any) {
        if let anyCodable = value as? AnyCodable {
            self.storage = anyCodable.storage
        } else if let val = value as? String {
            self.storage = .string(val)
        } else if let val = value as? Int {
            self.storage = .int(val)
        } else if let val = value as? Double {
            self.storage = .double(val)
        } else if let val = value as? Bool {
            self.storage = .bool(val)
        } else if let val = value as? [String: Any] {
            self.storage = .dictionary(val.mapValues { AnyCodable($0) })
        } else if let val = value as? [Any] {
            self.storage = .array(val.map { AnyCodable($0) })
        } else if let val = value as? Int64 {
            self.storage = .int64(val)
        } else {
            self.storage = .string(String(describing: value))
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.storage = .string("")
        } else if let val = try? container.decode(Bool.self) {
            self.storage = .bool(val)
        } else if let val = try? container.decode(Int.self) {
            self.storage = .int(val)
        } else if let val = try? container.decode(Double.self) {
            self.storage = .double(val)
        } else if let val = try? container.decode(String.self) {
            self.storage = .string(val)
        } else if let val = try? container.decode([String: AnyCodable].self) {
            self.storage = .dictionary(val)
        } else if let val = try? container.decode([AnyCodable].self) {
            self.storage = .array(val)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable value cannot be decoded")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch storage {
        case .string(let val):
            try container.encode(val)
        case .int(let val):
            try container.encode(val)
        case .double(let val):
            try container.encode(val)
        case .bool(let val):
            try container.encode(val)
        case .dictionary(let val):
            try container.encode(val)
        case .array(let val):
            try container.encode(val)
        case .int64(let val):
            try container.encode(val)
        }
    }
    
    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        return lhs.storage == rhs.storage
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage)
    }
}
