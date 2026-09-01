import Foundation

enum IdentityDisplayFormatter {
    static func displayName(handle: String, contactName: String?) -> String {
        if let contactName, !contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return contactName
        }

        if let business = businessLabel(for: handle) {
            return business
        }

        return PhoneUtils.formatDisplay(handle)
    }

    static func displayName(handle: String, resolver: ContactResolver) async -> String {
        let contactName = await resolver.resolve(handle)
        return displayName(handle: handle, contactName: contactName)
    }

    static func participants(_ participants: [ChatIdentity.Participant]) -> [ChatParticipant] {
        let unique = uniqueByHandle(participants)
        let names = disambiguatedNames(for: unique)
        return zip(unique, names).map { participant, name in
            ChatParticipant(name: name, handle: participant.handle)
        }
    }

    static func previewNames(
        selected: [ChatIdentity.Participant],
        allParticipants: [ChatIdentity.Participant]
    ) -> [String] {
        let uniqueAll = uniqueByHandle(allParticipants)
        let uniqueSelected = uniqueByHandle(selected)
        let allNames = disambiguatedNames(for: uniqueAll)
        // Participant lists come from chat_handle_join, which can carry the
        // same handle twice; the first entry is the one callers ordered for.
        let nameByHandle = Dictionary(zip(uniqueAll.map(\.handle), allNames), uniquingKeysWith: { first, _ in first })
        return uniqueSelected.map { nameByHandle[$0.handle] ?? $0.displayName }
    }

    private static func uniqueByHandle(
        _ participants: [ChatIdentity.Participant]
    ) -> [ChatIdentity.Participant] {
        var seen: Set<String> = []
        return participants.filter { seen.insert($0.handle).inserted }
    }

    private static func disambiguatedNames(for participants: [ChatIdentity.Participant]) -> [String] {
        let unique = uniqueByHandle(participants)
        let counts = Dictionary(grouping: unique, by: \.displayName).mapValues(\.count)
        return unique.map { participant in
            guard (counts[participant.displayName] ?? 0) > 1 else {
                return participant.displayName
            }
            return "\(participant.displayName) (\(disambiguator(for: participant.handle)))"
        }
    }

    private static func disambiguator(for handle: String) -> String {
        let digits = handle.filter(\.isNumber)
        if digits.count >= 4 {
            return String(digits.suffix(4))
        }

        if let atIndex = handle.firstIndex(of: "@"), atIndex > handle.startIndex {
            return String(handle[..<atIndex])
        }

        return handle
    }

    private static func businessLabel(for handle: String) -> String? {
        let lowercased = handle.lowercased()
        guard lowercased.hasSuffix("@rbm.goog") else { return nil }

        let localPart = lowercased.split(separator: "@").first.map(String.init) ?? lowercased
        let firstToken = localPart.split(separator: "_").first.map(String.init) ?? localPart
        let cleaned = firstToken.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        return cleaned
            .split(separator: " ")
            .map { token in
                let lower = token.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}
