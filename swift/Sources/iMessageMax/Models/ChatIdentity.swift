import Foundation

/// Canonical conversation identity shared across discovery, retrieval, and sending.
struct ChatIdentity: Codable {
    let mcpId: String
    let guid: String?
    let displayName: String
    let explicitName: String?
    let isNamed: Bool
    let participantCount: Int
    let participants: [Participant]
    let aliases: [String]

    enum CodingKeys: String, CodingKey {
        case mcpId = "mcp_id"
        case guid
        case displayName = "display_name"
        case explicitName = "explicit_name"
        case isNamed = "is_named"
        case participantCount = "participant_count"
        case participants
        case aliases
    }

    struct Participant: Codable {
        let handle: String
        let displayName: String
        let contactName: String?

        enum CodingKeys: String, CodingKey {
            case handle
            case displayName = "display_name"
            case contactName = "contact_name"
        }
    }

    static func makeParticipant(
        handle: String,
        contactName: String?
    ) -> Participant {
        Participant(
            handle: handle,
            displayName: contactName ?? PhoneUtils.formatDisplay(handle),
            contactName: contactName
        )
    }

    static func sortParticipants(_ participants: [Participant]) -> [Participant] {
        participants.sorted {
            let lhsName = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if lhsName != .orderedSame {
                return lhsName == .orderedAscending
            }
            return $0.handle.localizedCaseInsensitiveCompare($1.handle) == .orderedAscending
        }
    }

    init(
        mcpId: String,
        guid: String?,
        explicitName: String?,
        participants: [Participant]
    ) {
        let normalizedParticipants = ChatIdentity.sortParticipants(participants)
        let trimmedExplicitName = explicitName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExplicitName = (trimmedExplicitName?.isEmpty == false) ? trimmedExplicitName : nil
        let participantDisplayNames = normalizedParticipants.map(\.displayName)

        self.mcpId = mcpId
        self.guid = guid
        self.explicitName = normalizedExplicitName
        self.isNamed = normalizedExplicitName != nil
        self.displayName = normalizedExplicitName ?? DisplayNameGenerator.fromNames(participantDisplayNames)
        self.participantCount = normalizedParticipants.count
        self.participants = normalizedParticipants
        self.aliases = ChatIdentity.buildAliases(
            displayName: self.displayName,
            explicitName: normalizedExplicitName,
            participants: normalizedParticipants
        )
    }

    private static func buildAliases(
        displayName: String,
        explicitName: String?,
        participants: [Participant]
    ) -> [String] {
        var aliases: [String] = []

        func addAlias(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let normalized = trimmed.lowercased()
            if !aliases.contains(normalized) {
                aliases.append(normalized)
            }
        }

        addAlias(displayName)
        addAlias(explicitName)

        if !participants.isEmpty {
            addAlias(participants.map(\.displayName).joined(separator: ", "))
        }

        for participant in participants {
            addAlias(participant.displayName)
            addAlias(participant.contactName)
            addAlias(participant.handle)
        }

        return aliases
    }
}
