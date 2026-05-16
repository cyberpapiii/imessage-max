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
        let names = disambiguatedNames(for: participants)
        return zip(participants, names).map { participant, name in
            ChatParticipant(name: name, handle: participant.handle)
        }
    }

    static func previewNames(
        selected: [ChatIdentity.Participant],
        allParticipants: [ChatIdentity.Participant]
    ) -> [String] {
        let allNames = disambiguatedNames(for: allParticipants)
        let nameByHandle = Dictionary(uniqueKeysWithValues: zip(allParticipants.map(\.handle), allNames))
        return selected.map { nameByHandle[$0.handle] ?? $0.displayName }
    }

    private static func disambiguatedNames(for participants: [ChatIdentity.Participant]) -> [String] {
        let counts = Dictionary(grouping: participants, by: \.displayName).mapValues(\.count)
        return participants.map { participant in
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
