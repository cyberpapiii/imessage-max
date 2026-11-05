import Foundation

/// Who a `from_person` argument names, resolved the same way for every tool.
enum SenderFilter: Equatable {
    case me
    /// Exact `handle.id` values: a normalized phone number, an email, or
    /// every handle of every contact whose name matches.
    case handles([String])
    /// Nothing resolved, so match the text inside handles.
    case handleContains(String)

    static func resolve(_ fromPerson: String?, resolver: ContactResolver) async -> SenderFilter? {
        guard let fromPerson, !fromPerson.isEmpty else { return nil }
        if fromPerson.lowercased() == "me" {
            return .me
        }
        if let normalized = PhoneUtils.normalizeToE164(fromPerson) {
            return .handles([normalized])
        }
        if PhoneUtils.isEmail(fromPerson) {
            return .handles([fromPerson.lowercased()])
        }
        let matches = Set(await resolver.searchByName(fromPerson).map(\.handle))
        if !matches.isEmpty {
            return .handles(matches.sorted())
        }
        return .handleContains(fromPerson)
    }

    /// A predicate over `m` and the sender join `h`.
    var predicate: (sql: String, params: [Any]) {
        switch self {
        case .me:
            return ("m.is_from_me = 1", [])
        case .handles(let handles):
            return ("h.id IN (\(SQLFragments.placeholders(handles.count)))", handles)
        case .handleContains(let text):
            return ("h.id LIKE ? ESCAPE '\\'", ["%\(QueryBuilder.escapeLike(text))%"])
        }
    }
}

extension QueryBuilder {
    @discardableResult
    func `where`(_ sender: SenderFilter) -> QueryBuilder {
        let predicate = sender.predicate
        return `where`(predicate.sql, params: predicate.params)
    }
}
