import MCP

struct IntArgument: Sendable {
    let name: String
    let defaultValue: Int
    let range: ClosedRange<Int>

    var defaultAndMax: String { "default \(defaultValue), max \(range.upperBound)" }

    func clamp(_ value: Int) -> Int { min(max(value, range.lowerBound), range.upperBound) }

    func read(_ arguments: [String: Value]?) -> Int { clamp(arguments?[name]?.intValue ?? defaultValue) }

    static let unansweredHours = IntArgument(name: "unanswered_hours", defaultValue: 24, range: 1...(24 * 365))
}
