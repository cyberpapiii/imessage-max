import MCP

/// An integer tool argument. Its default and bounds feed both the schema
/// text the client reads and the clamp the tool applies, so they can't drift.
struct IntArgument: Sendable {
    let name: String
    let defaultValue: Int
    let range: ClosedRange<Int>

    /// "default 20, max 100", for schema descriptions.
    var defaultAndMax: String { "default \(defaultValue), max \(range.upperBound)" }

    func clamp(_ value: Int) -> Int { min(max(value, range.lowerBound), range.upperBound) }

    func read(_ arguments: [String: Value]?) -> Int { clamp(arguments?[name]?.intValue ?? defaultValue) }

    /// Shared by search and get_messages.
    static let unansweredHours = IntArgument(name: "unanswered_hours", defaultValue: 24, range: 1...(24 * 365))
}
