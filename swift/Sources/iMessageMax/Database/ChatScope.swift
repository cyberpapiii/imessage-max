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

    /// Narrows a query whose chat `alias` is joined on `listedChat()`: to
    /// the named chat's messages, or to shown chats when hidden ones are left out.
    func narrow(_ query: QueryBuilder, chat alias: String = "c", message messageId: String = "m.ROWID") {
        if let named {
            query.where(SQLFragments.messageInChat(messageId), named)
        } else if hidesChats {
            query.where(SQLFragments.shownChat(alias))
        }
    }

    /// `filtered_hidden`: absent with include_filtered and past a listing's
    /// first page, 0 for a named chat (which hides nothing), else `count`.
    func filteredHidden(firstPage: Bool = true, count: () throws -> Int) rethrows -> Int? {
        guard !includeFiltered && firstPage else { return nil }
        return hidesChats ? try count() : 0
    }
}
