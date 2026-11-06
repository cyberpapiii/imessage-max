import Foundation

enum DisplayNameGenerator {
    static func fromNames(_ names: [String]) -> String {
        if names.isEmpty { return "Unknown Chat" }
        if names.count <= 4 {
            return names.joined(separator: ", ")
        }
        let first3 = names.prefix(3).joined(separator: ", ")
        return "\(first3) and \(names.count - 3) others"
    }
}
