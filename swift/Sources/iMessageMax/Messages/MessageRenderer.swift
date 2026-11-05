import Foundation

enum MessageRenderer {
    static func reactions(
        _ rows: [MessageAnnotations.Reaction],
        reactorName: (String?) -> String
    ) -> [String]? {
        var reactionStrings: [String] = []
        for r in applyingRemovals(rows) {
            guard let reactionType = ReactionType(rawValue: r.type) else { continue }

            let token: String
            switch reactionType {
            case .customEmoji:
                token = r.emoji ?? "?"
            case .sticker:
                token = ReactionType.stickerToken
            default:
                token = reactionType.emoji
            }
            reactionStrings.append("\(token) \(reactorName(r.fromHandle))")
        }
        return reactionStrings.isEmpty ? nil : reactionStrings
    }

    static func applyingRemovals(_ rows: [MessageAnnotations.Reaction]) -> [MessageAnnotations.Reaction] {
        let sorted = rows.sorted { $0.date < $1.date }
        struct Key: Hashable {
            let handle: String?
            let type: Int
        }
        var kept: [Key: MessageAnnotations.Reaction] = [:]
        var order: [Key] = []

        for r in sorted {
            if ReactionType.isRemoval(r.type) {
                let key = Key(handle: r.fromHandle, type: r.type - 1000)
                if kept.removeValue(forKey: key) != nil {
                    order.removeAll { $0 == key }
                }
            } else if ReactionType(rawValue: r.type) != nil {
                let key = Key(handle: r.fromHandle, type: r.type)
                if kept[key] == nil {
                    order.append(key)
                }
                kept[key] = r
            }
        }

        return order.compactMap { kept[$0] }
    }

    static func links(in text: String) -> [String] {
        let pattern = #"https?://[^\s<>\"{}|\\^`\[\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
