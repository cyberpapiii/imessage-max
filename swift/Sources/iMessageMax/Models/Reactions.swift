// Sources/iMessageMax/Models/Reactions.swift
import Foundation

enum ReactionType: Int {
    case loved = 2000
    case liked = 2001
    case disliked = 2002
    case laughed = 2003
    case emphasized = 2004
    case questioned = 2005

    // Removal types are 3000-3005
    static func isRemoval(_ type: Int) -> Bool {
        type >= 3000 && type < 3006
    }

    var emoji: String {
        switch self {
        case .loved: return "❤️"
        case .liked: return "👍"
        case .disliked: return "👎"
        case .laughed: return "😂"
        case .emphasized: return "‼️"
        case .questioned: return "❓"
        }
    }

    static func fromType(_ type: Int) -> ReactionType? {
        ReactionType(rawValue: type)
    }
}
