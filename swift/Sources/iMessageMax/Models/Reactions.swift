// Sources/iMessageMax/Models/Reactions.swift
import Foundation

enum ReactionType: Int {
    case loved = 2000
    case liked = 2001
    case disliked = 2002
    case laughed = 2003
    case emphasized = 2004
    case questioned = 2005
    case customEmoji = 2006
    case sticker = 2007

    /// Live chat.db also has types 4000 (12 rows) and 4001 (4 rows).
    /// Meaning is not established; they stay unmapped and unfiltered.
    static let stickerToken = "🩵 sticker"

    // Removal types are 3000-3007 (3006 = custom emoji, 3007 = sticker).
    static func isRemoval(_ type: Int) -> Bool {
        type >= 3000 && type < 3008
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
        case .sticker: return Self.stickerToken
        }
    }
}
