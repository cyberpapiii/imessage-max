import Foundation

enum SenderFilter: Equatable {
    case me
    case handles([String])
    case handleContains(String)

    static func resolve(_ fromPerson: String?, resolver: ContactResolver) async -> SenderFilter? {
        guard let fromPerson, !fromPerson.isEmpty else { return nil }
        if fromPerson.lowercased() == "me" {
            return .me
        }
        let handles = await exactHandles(for: fromPerson, resolver: resolver)
        return handles.isEmpty ? .handleContains(fromPerson) : .handles(handles)
    }

    static func exactHandles(for person: String, resolver: ContactResolver) async -> [String] {
        if let normalized = PhoneUtils.normalizeToE164(person) {
            return [normalized]
        }
        if PhoneUtils.isEmail(person) {
            return [person.lowercased()]
        }
        return Set(await resolver.searchByName(person).map(\.handle)).sorted()
    }

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
