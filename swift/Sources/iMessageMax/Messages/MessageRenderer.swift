import Foundation

/// How a tool names a message's sender and its reactors. Tools differ on
/// purpose (people-map keys vs display names, "me" vs "Me"), so each picks
/// its labels here and the renderer applies them the same way everywhere.
struct SenderLabels {
    enum Missing {
        /// Show the raw handle.
        case handle
        /// Show this fixed label.
        case label(String)
    }

    let me: String
    /// A received message whose sender handle is NULL.
    let noHandle: String
    let names: [String: String]
    var missingSender: Missing = .handle
    var missingReactor: Missing = .handle

    func sender(_ message: MessageRecord) -> String {
        if message.isFromMe { return me }
        guard let handle = message.senderHandle else { return noHandle }
        return name(handle, missing: missingSender)
    }

    /// chat.db stores my own tapbacks with no handle.
    func reactor(_ handle: String?) -> String {
        guard let handle else { return me }
        return name(handle, missing: missingReactor)
    }

    private func name(_ handle: String, missing: Missing) -> String {
        if let name = names[handle] { return name }
        switch missing {
        case .handle: return handle
        case .label(let label): return label
        }
    }

    /// Contact name, business label or formatted number for every sender
    /// and reactor in `messages`.
    static func displayNames(
        me: String,
        unknown: String,
        for messages: [MessageRecord],
        annotations: MessageAnnotations = .none,
        resolver: ContactResolver
    ) async -> SenderLabels {
        var handles = messages.compactMap(\.senderHandle)
        for message in messages {
            handles += (annotations.reactions[message.guid] ?? []).compactMap(\.fromHandle)
        }
        return SenderLabels(
            me: me,
            noHandle: unknown,
            names: await displayNames(handles, resolver: resolver)
        )
    }

    static func displayNames(_ handles: [String], resolver: ContactResolver) async -> [String: String] {
        var names: [String: String] = [:]
        for handle in handles where names[handle] == nil {
            names[handle] = await IdentityDisplayFormatter.displayName(handle: handle, resolver: resolver)
        }
        return names
    }
}

/// Every part of a message a tool may show, computed one way.
struct RenderedMessage {
    let id: String
    let rowid: Int64
    let from: String
    let text: String?
    let ts: String?
    let ago: String?
    let reactions: [String]?
    let replyTo: String?
    let replyCount: Int?
    let edited: Bool?
    let event: GroupEvent?
    let attachments: [MessageAttachmentSummary]?
    let links: [String]?
}

struct MessageAttachmentSummary: Encodable {
    let id: String
    let type: String
    let filename: String?
    let size: Int?

    init(_ attachment: MessageAnnotations.Attachment) {
        id = AttachmentIdentifier.format(attachment.id)
        type = AttachmentType.from(mimeType: attachment.mimeType, uti: attachment.uti).rawValue
        filename = attachment.filename?.components(separatedBy: "/").last
        size = attachment.totalBytes
    }
}

struct MessageRenderer {
    let annotations: MessageAnnotations
    let labels: SenderLabels
    /// Display names for group-event targets (`message.other_handle`).
    var eventNames: [String: String] = [:]

    /// Links shown per message; the text itself still carries the rest.
    static let maxLinks = 10

    /// Resolves the display names group events show for the people they
    /// added or removed.
    static func eventNames(for messages: [MessageRecord], resolver: ContactResolver) async -> [String: String] {
        await SenderLabels.displayNames(messages.compactMap(\.otherHandle), resolver: resolver)
    }

    func render(_ message: MessageRecord) -> RenderedMessage {
        let date = AppleTime.toDate(message.date)
        let attachments = (annotations.attachments[message.id] ?? []).map(MessageAttachmentSummary.init)
        let links = Array((message.text.map(Self.links(in:)) ?? []).prefix(Self.maxLinks))
        return RenderedMessage(
            id: MessageIdentifier.format(message.id),
            rowid: message.id,
            from: labels.sender(message),
            text: message.text,
            ts: TimeUtils.formatISO(date),
            ago: TimeUtils.formatCompactRelative(date),
            reactions: Self.reactions(annotations.reactions[message.guid] ?? [], reactorName: labels.reactor),
            replyTo: annotations.replyTo(message),
            replyCount: annotations.replyCount(message),
            edited: message.isEdited ? true : nil,
            event: GroupEvent.classify(
                itemType: message.itemType,
                groupActionType: message.groupActionType,
                groupTitle: message.groupTitle,
                otherHandleName: message.otherHandle.flatMap { eventNames[$0] }
            ),
            attachments: attachments.isEmpty ? nil : attachments,
            links: links.isEmpty ? nil : links
        )
    }

    static func reactions(
        _ rows: [MessageAnnotations.Reaction],
        reactorName: (String?) -> String
    ) -> [String]? {
        var reactionStrings: [String] = []
        for r in applyingRemovals(rows) {
            guard let reactionType = ReactionType(rawValue: r.type) else { continue }

            let token: String
            switch reactionType {
            case .customEmoji:
                token = r.emoji ?? "?"
            case .sticker:
                token = ReactionType.stickerToken
            default:
                token = reactionType.emoji
            }
            reactionStrings.append("\(token) \(reactorName(r.fromHandle))")
        }
        return reactionStrings.isEmpty ? nil : reactionStrings
    }

    static func applyingRemovals(_ rows: [MessageAnnotations.Reaction]) -> [MessageAnnotations.Reaction] {
        let sorted = rows.sorted { $0.date < $1.date }
        struct Key: Hashable {
            let handle: String?
            let type: Int
        }
        var kept: [Key: MessageAnnotations.Reaction] = [:]
        var order: [Key] = []

        for r in sorted {
            if ReactionType.isRemoval(r.type) {
                let key = Key(handle: r.fromHandle, type: r.type - 1000)
                if kept.removeValue(forKey: key) != nil {
                    order.removeAll { $0 == key }
                }
            } else if ReactionType(rawValue: r.type) != nil {
                let key = Key(handle: r.fromHandle, type: r.type)
                if kept[key] == nil {
                    order.append(key)
                }
                kept[key] = r
            }
        }

        return order.compactMap { kept[$0] }
    }

    static func links(in text: String) -> [String] {
        let pattern = #"https?://[^\s<>\"{}|\\^`\[\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}

/// A message shown beside another one: get_context's window and search's
/// include_context. Only get_context shows `ago`.
struct ContextMessage: Codable {
    let id: String
    let from: String
    let text: String?
    let ago: String?
    let ts: String?
    let reactions: [String]?
    let replyTo: String?
    let replyCount: Int?
    let edited: Bool?

    enum CodingKeys: String, CodingKey {
        case id, from, text, ago, ts, reactions
        case replyTo = "reply_to"
        case replyCount = "reply_count"
        case edited
    }

    init(_ message: RenderedMessage, showAgo: Bool) {
        id = message.id
        from = message.from
        text = message.text
        ago = showAgo ? message.ago : nil
        ts = message.ts
        reactions = message.reactions
        replyTo = message.replyTo
        replyCount = message.replyCount
        edited = message.edited
    }
}
