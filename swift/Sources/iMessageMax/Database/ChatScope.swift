import Foundation

/// Which chats a message tool reads, and the one chat it lists each message
/// under. The hidden-chat rule for every tool: a chat named by id is shown
/// even when Messages.app hides it; otherwise hidden chats are left out
/// unless the caller passed include_filtered.
struct ChatScope {
    /// The chat the caller named by id, if any.
    let named: Int64?
    let includeFiltered: Bool

    init(named: Int64?, includeFiltered: Bool) {
        self.named = named
        self.includeFiltered = includeFiltered
    }

    /// A tool without include_filtered that finds a message by its own id
    /// lists it where search and get_unread do by default.
    static let byMessage = ChatScope(named: nil, includeFiltered: false)

    /// Hidden chats are left out, and so counted in `filtered_hidden`.
    var hidesChats: Bool { named == nil && !includeFiltered }

    /// The chat predicate for a query over chat membership (one row per
    /// chat a message is in), nil when every chat is read.
    func shownPredicate(_ alias: String = "c") -> String? {
        hidesChats ? SQLFragments.shownChat(alias) : nil
    }

    /// SQL for the chat message `messageId` is listed under: the named chat,
    /// else its home chat.
    func listedChat(of messageId: String = "m.ROWID") -> String {
        named.map(String.init) ?? SQLFragments.homeChat(of: messageId, preferShown: hidesChats)
    }

    /// Reads messages `m` into `query`, each joined to the one chat `c` it
    /// is listed under. A named chat's messages come from
    /// chat_message_join by chat id (its primary key): CROSS JOIN pins
    /// SQLite's loop order to the chat, its join rows, then each message by
    /// rowid, so a named chat never walks every message checking each one's
    /// chats. Otherwise each message joins its home chat, and hidden chats
    /// are left out when the scope hides them.
    ///
    /// `screened: false` is for a caller that sorts the rows itself: an
    /// unnamed read then keeps a message whose chat is hidden or not joined
    /// yet (`c` NULL). Call before the query's other joins and predicates.
    func read(_ query: QueryBuilder, screened: Bool = true) {
        if let named {
            query
                .from("""
                    chat c
                    CROSS JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    CROSS JOIN message m ON m.ROWID = cmj.message_id
                    """)
                .where("c.ROWID = ?", named)
            return
        }
        query.from("message m")
        let chat = "chat c ON c.ROWID = \(listedChat())"
        guard screened else {
            query.leftJoin(chat)
            return
        }
        query.join(chat)
        if let shown = shownPredicate() {
            query.where(shown)
        }
    }

    /// The message rowid column for a range or order over a `read` query:
    /// the join row's under a named chat, so the range seeks its primary key.
    var messageRowid: String { named == nil ? "m.ROWID" : "cmj.message_id" }

    /// `filtered_hidden`: absent with include_filtered and past a listing's
    /// first page, 0 for a named chat (which hides nothing), else `count`.
    func filteredHidden(firstPage: Bool = true, count: () throws -> Int) rethrows -> Int? {
        guard !includeFiltered && firstPage else { return nil }
        return hidesChats ? try count() : 0
    }
}
