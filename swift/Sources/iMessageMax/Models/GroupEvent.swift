import Foundation

/// A group-chat system message (rename, membership change, leave).
/// Apple stores these as `message` rows with `item_type != 0` and no text.
struct GroupEvent: Encodable, Equatable {
    enum Kind: String, Encodable, Equatable {
        case rename, participantAdded = "participant_added",
             participantRemoved = "participant_removed", left, other
    }
    let type: Kind
    let title: String?          // rename only
    let participant: String?    // added/removed, resolved display name
    let itemType: Int?          // set only for .other

    private enum CodingKeys: String, CodingKey {
        case type, title, participant
        case itemType = "item_type"
    }

    /// Classifies the raw columns. `otherHandleId` is the `handle.id` string
    /// already joined from `message.other_handle`, or nil.
    static func classify(
        itemType: Int,
        groupActionType: Int,
        groupTitle: String?,
        otherHandleName: String?
    ) -> GroupEvent? {
        guard itemType != 0 else { return nil }

        switch itemType {
        case 1 where groupActionType == 0:
            return GroupEvent(
                type: .participantAdded,
                title: nil,
                participant: otherHandleName ?? "someone",
                itemType: nil
            )
        case 1 where groupActionType == 1:
            return GroupEvent(
                type: .participantRemoved,
                title: nil,
                participant: otherHandleName ?? "someone",
                itemType: nil
            )
        case 2:
            return GroupEvent(
                type: .rename,
                title: groupTitle,
                participant: nil,
                itemType: nil
            )
        case 3:
            return GroupEvent(
                type: .left,
                title: nil,
                participant: nil,
                itemType: nil
            )
        default:
            return GroupEvent(
                type: .other,
                title: nil,
                participant: nil,
                itemType: itemType
            )
        }
    }

    /// Short preview phrase, e.g. "renamed the group to Trip".
    var previewText: String {
        switch type {
        case .rename:
            if let title, !title.isEmpty {
                return "renamed the group to \(title)"
            }
            return "renamed the group"
        case .participantAdded:
            return "added \(participant ?? "someone")"
        case .participantRemoved:
            return "removed \(participant ?? "someone")"
        case .left:
            return "left the group"
        case .other:
            return "[group event]"
        }
    }
}
