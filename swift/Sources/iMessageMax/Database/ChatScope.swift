import Foundation

struct ChatScope {
    let named: Int64?
    let includeFiltered: Bool

    init(named: Int64?, includeFiltered: Bool) {
        self.named = named
        self.includeFiltered = includeFiltered
    }

    static let byMessage = ChatScope(named: nil, includeFiltered: false)

    var hidesChats: Bool { named == nil && !includeFiltered }

    func shownPredicate(_ alias: String = "c") -> String? {
        hidesChats ? SQLFragments.shownChat(alias) : nil
    }

    func listedChat(of messageId: String = "m.ROWID") -> String {
        named.map(String.init) ?? SQLFragments.homeChat(of: messageId, preferShown: hidesChats)
    }

    /// Reads messages `m` into `query` and joins each one to the one chat `c`
    /// that lists it. A named chat's messages come from chat_message_join by
    /// chat id, which uses that table's primary key. CROSS JOIN fixes
    /// SQLite's loop order to the chat, then its join rows, then each message
    /// by rowid. A named chat therefore never scans every message to check
    /// each one's chats. Without a named chat, each message joins its home
    /// chat, and the query leaves out hidden chats when the scope hides them.
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

    /// The message rowid column for a range or an order on a `read` query.
    /// Under a named chat it is the join row's message id, so the range seeks
    /// chat_message_join's primary key.
    var messageRowid: String { named == nil ? "m.ROWID" : "cmj.message_id" }

    func filteredHidden(firstPage: Bool = true, count: () throws -> Int) rethrows -> Int? {
        guard !includeFiltered && firstPage else { return nil }
        return hidesChats ? try count() : 0
    }
}
