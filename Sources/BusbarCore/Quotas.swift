import Foundation

/// A flat bag of EcoFlow "quota" values, e.g. `"pd.soc": "78"`.
///
/// The API is inconsistent about types (the HTTP endpoint returns numbers as
/// strings, MQTT sometimes as numbers), so everything is normalised to `Double`.
public struct Quotas: Sendable, Equatable {
    public private(set) var values: [String: Double]

    public init(_ values: [String: Double] = [:]) {
        self.values = values
    }

    /// Builds quotas from a decoded JSON object, ignoring values that aren't numeric.
    public init(json: [String: Any]) {
        var values: [String: Double] = [:]
        for (key, raw) in json {
            switch raw {
            case let number as NSNumber: values[key] = number.doubleValue
            case let string as String: if let d = Double(string) { values[key] = d }
            default: break
            }
        }
        self.values = values
    }

    public subscript(key: String) -> Double? { values[key] }

    public func int(_ key: String) -> Int? { values[key].map { Int($0) } }

    /// MQTT pushes partial updates; merge them into the running state.
    public mutating func merge(_ other: Quotas) {
        values.merge(other.values) { _, new in new }
    }
}
