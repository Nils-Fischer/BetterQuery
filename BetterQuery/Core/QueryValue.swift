import Foundation

public enum QueryValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([QueryValue])
    case object([String: QueryValue])
}

public typealias QueryKey = [QueryValue]

public func hashKey(_ key: QueryKey) -> String {
    let payload = QueryValue.array(key).stableJSONString()
    return payload
}

func partialMatchKey(_ candidate: QueryValue, _ filter: QueryValue) -> Bool {
    if candidate == filter {
        return true
    }

    switch (candidate, filter) {
    case let (.array(lhs), .array(rhs)):
        guard lhs.count >= rhs.count else {
            return false
        }

        for (index, rhsValue) in rhs.enumerated() {
            if !partialMatchKey(lhs[index], rhsValue) {
                return false
            }
        }
        return true

    case let (.object(lhs), .object(rhs)):
        for (key, rhsValue) in rhs {
            guard let lhsValue = lhs[key], partialMatchKey(lhsValue, rhsValue) else {
                return false
            }
        }
        return true

    default:
        return false
    }
}

func partialMatchKey(_ candidate: QueryKey, _ filter: QueryKey) -> Bool {
    return partialMatchKey(.array(candidate), .array(filter))
}

extension QueryValue {
    fileprivate func stableJSONString() -> String {
        switch self {
        case .null:
            return "null"
        case let .bool(value):
            return value ? "true" : "false"
        case let .int(value):
            return String(value)
        case let .double(value):
            if value.isFinite {
                let number = NSNumber(value: value)
                return number.stringValue
            }
            return "null"
        case let .string(value):
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        case let .array(values):
            let items = values.map { $0.stableJSONString() }.joined(separator: ",")
            return "[\(items)]"
        case let .object(values):
            let items = values
                .keys
                .sorted()
                .map { key in
                    let escapedKey = QueryValue.string(key).stableJSONString()
                    let value = values[key] ?? .null
                    return "\(escapedKey):\(value.stableJSONString())"
                }
                .joined(separator: ",")
            return "{\(items)}"
        }
    }
}
