// Sources/iMessageMax/Models/Reactions.swift
import Foundation

/// A tapback's `associated_message_type`. Removing a tapback writes a new
/// row whose type is the tapback's plus 1000 (3000-3007).
///
/// Live chat.db also has types 4000 and 4001. Their meaning is not
/// established, so they are neither tapbacks nor removals here.
enum ReactionType: Int, CaseIterable {
    case loved = 2000
    case liked = 2001
    case disliked = 2002
    case laughed = 2003
    case emphasized = 2004
    case questioned = 2005
    case customEmoji = 2006
    case sticker = 2007

    static let removalOffset = 1000

    static let types = allCases.map(\.rawValue).min()!...allCases.map(\.rawValue).max()!
    static let removalTypes = (types.lowerBound + removalOffset)...(types.upperBound + removalOffset)

    /// The tapback a removal row of `type` takes back, or nil if `type` is not a removal.
    static func removed(by type: Int) -> ReactionType? {
        removalTypes.contains(type) ? ReactionType(rawValue: type - removalOffset) : nil
    }

    var emoji: String {
        switch self {
        case .loved: return "❤️"
        case .liked: return "👍"
        case .disliked: return "👎"
        case .laughed: return "😂"
        case .emphasized: return "‼️"
        case .questioned: return "❓"
        case .customEmoji: return "?"
        case .sticker: return "🩵 sticker"
        }
    }

    /// What a reaction string starts with: the custom emoji itself for 2006.
    func token(customEmoji: String?) -> String {
        self == .customEmoji ? customEmoji ?? emoji : emoji
    }
}
