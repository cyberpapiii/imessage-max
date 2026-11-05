import Foundation

/// chat.db predicates that encode Messages.app rules, so each rule is written once.
enum SQLFragments {
    /// `?, ?, ?` for an IN list of `count` bindings.
    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// `chat.is_filtered` is a bitmask; shown chats are exactly 0, so never test `!= 1`.
    static func shownChat(_ alias: String = "c") -> String { "\(alias).is_filtered = 0" }
    static func hiddenChat(_ alias: String = "c") -> String { "\(alias).is_filtered != 0" }

    /// Number of other participants in chat `alias` (chat_handle_join is unique per pair).
    static func participantCount(_ alias: String = "c") -> String {
        "(SELECT COUNT(*) FROM chat_handle_join pc WHERE pc.chat_id = \(alias).ROWID)"
    }

    /// Tapbacks and other associated messages carry a nonzero type.
    static func notReaction(_ alias: String = "m") -> String { "\(alias).associated_message_type = 0" }
}
