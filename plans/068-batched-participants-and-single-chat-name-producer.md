# Plan 068: Batch the per-chat participant, recent-sender, and attachment-type queries, and make `ChatIdentity` the only chat-name producer

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 639529e..HEAD -- swift/Sources/iMessageMax/Tools/SearchInternals.swift swift/Sources/iMessageMax/Utilities/PreviewResolvers.swift swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift swift/Sources/iMessageMax/Models/ChatIdentity.swift swift/Sources/iMessageMax/Utilities/IdentityDisplayFormatter.swift swift/Sources/iMessageMax/Tools/FindChat.swift swift/Sources/iMessageMax/Tools/ListChats.swift swift/Sources/iMessageMax/Tools/GetActiveConversations.swift swift/Sources/iMessageMax/Tools/GetUnread.swift swift/Sources/iMessageMax/Tools/GetContext.swift swift/Sources/iMessageMax/Tools/ListAttachments.swift swift/Sources/iMessageMax/Tools/SendResolution.swift swift/Tests/iMessageMaxTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: perf / tech-debt
- **Planned at**: commit `639529e`, 2026-09-01

## Why this matters

`ChatSummaryQueries.participantsByChat` exists precisely so list-style tools issue one participants query for N chats. Three call paths defeat it:

1. `search` (both the flat and grouped response builders) generates a chat name per row by calling `ChatSummaryQueries.participants` for one chat, then the grouped path calls `buildChatSummary` for the same chat, which runs the same participants query again. A 20-result search across 20 unnamed chats is 40 participants queries where 1 would do. Worse, the grouped path passes the *generated* name back in as `explicitName`, so `ChatIdentity.isNamed` becomes true for an unnamed chat and the summary takes the "named chat" preview branch.
2. `ChatSummaryBuilder.participantsPreview` runs a 50-row "recent inbound senders" query for every named chat with more than four participants. It is called once per row from `list_chats`, `find_chat`, `get_active_conversations`, and `get_unread`, so a `list_chats` page of 50 large named groups is 50 extra queries.
3. `ChatSummaryQueries.lastMessagesByChat` calls `MessagePreviewResolver.messageSummary` per row, which for every attachment-only message runs a separate `attachmentTypes` query.

Separately, there are five different pieces of code that turn a participant list into a chat display name, and they disagree: `search` uses first names only and does not sort; `get_context` and `send` sort by handle and use full display names; `list_attachments` sorts by name case-insensitively and skips `IdentityDisplayFormatter`; `ChatIdentity` sorts by display name. `find_chat` additionally hand-builds its `participants` array and skips the duplicate-name disambiguator that `get_chat_details` applies. The same chat can therefore have three different names depending on which tool the agent called.

After this plan: each of the four list tools and `search` issue a constant number of queries per page regardless of row count, and every chat name and participant list comes from `ChatIdentity` and `IdentityDisplayFormatter`.

## Current state

### The batched layer that already exists

`swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift:9-13, 28-32, 84-90`:

```swift
    struct Participant {
        let handle: String
        let name: String?
        let service: String?
    }
    ...
    static func participantsByChat(
        db: Database,
        chatIds: [Int64],
        resolver: ContactResolver
    ) async throws -> [Int64: [Participant]] {
    ...
    /// Single-chat wrapper around `participantsByChat`.
    static func participants(
        db: Database,
        chatId: Int64,
        resolver: ContactResolver
    ) async throws -> [Participant] {
        try await participantsByChat(db: db, chatIds: [chatId], resolver: resolver)[chatId] ?? []
    }
```

Other batched helpers in the same file: `participantCountsByChat` (`:94`), `lastMessageDatesByChat` (`:123`), `lastMessagesByChat` (`:175`).

### Search: per-row name generation, then a second participants query

`swift/Sources/iMessageMax/Tools/SearchInternals.swift:206-221` (flat path; the grouped path at `:270-281` is identical):

```swift
            var chatName = row.chatDisplayName
            if chatName == nil || chatName?.isEmpty == true {
                if let cached = chatNamesCache[row.chatId] {
                    chatName = cached
                } else {
                    let generatedName = try await generateChatDisplayName(
                        db: db, chatId: row.chatId, resolver: resolver
                    )
                    chatNamesCache[row.chatId] = generatedName
                    chatName = generatedName
                }
            }

            var result = SearchResult(
                id: "msg_\(row.msgId)",
                chat: ChatReference(id: "chat\(row.chatId)", name: chatName ?? "Unknown Chat"),
```

`SearchInternals.swift:283-295` (grouped path, the double query and the `explicitName` misuse):

```swift
            let chatSummary: ChatSummary
            if let cached = chatSummaryCache[chatId] {
                chatSummary = cached
            } else {
                let summary = try await buildChatSummary(
                    db: db,
                    chatId: chatId,
                    explicitName: chatName,
                    resolver: resolver
                )
```

`SearchInternals.swift:568-590` (`buildChatSummary`, second participants query for the same chat):

```swift
    static func buildChatSummary(
        db: Database,
        chatId: Int64,
        explicitName: String?,
        resolver: ContactResolver
    ) async throws -> ChatSummary {
        let participants = try await ChatSummaryQueries.participants(
            db: db,
            chatId: chatId,
            resolver: resolver
        )
        let identityParticipants = participants.map {
            ChatIdentity.makeParticipant(handle: $0.handle, contactName: $0.name)
        }

        let identity = ChatIdentity(
            mcpId: "chat\(chatId)",
            guid: nil,
            explicitName: explicitName,
            participants: identityParticipants
        )
        return try ChatSummaryBuilder.buildSummary(db: db, chatId: chatId, identity: identity)
    }
```

`SearchInternals.swift:642-667` (`generateChatDisplayName`, name producer #1: first word of the contact name, insertion order, no `IdentityDisplayFormatter`):

```swift
    static func generateChatDisplayName(
        db: Database,
        chatId: Int64,
        resolver: ContactResolver
    ) async throws -> String {
        let participants = try await ChatSummaryQueries.participants(
            db: db,
            chatId: chatId,
            resolver: resolver
        )

        if participants.isEmpty {
            return "Unknown Chat"
        }

        var names: [String] = []
        for participant in participants {
            if let name = participant.name {
                names.append(name.split(separator: " ").first.map(String.init) ?? name)
            } else {
                names.append(PhoneUtils.formatDisplay(participant.handle))
            }
        }

        return DisplayNameGenerator.fromNames(names)
    }
```

### ChatIdentity is the intended single producer

`swift/Sources/iMessageMax/Models/ChatIdentity.swift:58-75`:

```swift
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
```

`makeParticipant(handle:contactName:)` at `:37-46` routes through `IdentityDisplayFormatter.displayName`. `sortParticipants` at `:48-56` sorts by display name (case-insensitive), then handle. `DisplayNameGenerator.fromNames` (`Utilities/DisplayNameGenerator.swift:6-13`) returns `"Unknown Chat"` for an empty list, joins up to four with `", "`, else `"A, B, C and N others"`.

### The other name producers

`swift/Sources/iMessageMax/Tools/GetContext.swift:460-481` (#2, sorts by handle, full display names):

```swift
    private static func displayNameForChat(
        chatId: Int64,
        explicitName: String?,
        database: Database,
        resolver: ContactResolver
    ) async throws -> String {
        let trimmed = explicitName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }

        let rows = try await ChatSummaryQueries.participants(
            db: database,
            chatId: chatId,
            resolver: resolver
        ).sorted { $0.handle < $1.handle }

        let names = rows.map {
            IdentityDisplayFormatter.displayName(handle: $0.handle, contactName: $0.name)
        }
        return DisplayNameGenerator.fromNames(names)
    }
```

`swift/Sources/iMessageMax/Tools/ListAttachments.swift:510-537` (#3, sorts by *name*, skips `IdentityDisplayFormatter`, so a business handle or a handle-only participant formats differently):

```swift
        let rows = try await ChatSummaryQueries.participants(
            db: db,
            chatId: chatId,
            resolver: resolver
        )
        let names = rows.map {
            $0.name ?? PhoneUtils.formatDisplay($0.handle)
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let generated = DisplayNameGenerator.fromNames(names)
```

`swift/Sources/iMessageMax/Tools/SendResolution.swift:64-90` (#4, sorts by handle; the `deliveredTo` list at `:73-75` reuses the same names, which is fine):

```swift
            let participants = try await ChatSummaryQueries.participants(
                db: db,
                chatId: Int64(numericId),
                resolver: resolver
            ).sorted { $0.handle < $1.handle }
            ...
            let displayNames = participants.map {
                IdentityDisplayFormatter.displayName(handle: $0.handle, contactName: $0.name)
            }
            ...
                    chat: ChatReference(
                        id: "chat\(numericId)",
                        name: {
                            let trimmed = chat.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let trimmed, !trimmed.isEmpty {
                                return trimmed
                            }
                            return DisplayNameGenerator.fromNames(displayNames)
                        }()
                    )
```

(#5 is `ChatIdentity` itself, the one to keep.)

### FindChat hand-builds participants and skips the disambiguator

`swift/Sources/iMessageMax/Tools/FindChat.swift:518-538`:

```swift
        for chat in chats {
            let participantRows = (participantsByChat[chat.id] ?? []).sorted { $0.handle < $1.handle }

            var participants: [ChatParticipant] = []
            var identityParticipants: [ChatIdentity.Participant] = []
            for p in participantRows {
                let identityParticipant = ChatIdentity.makeParticipant(
                    handle: p.handle,
                    contactName: p.name
                )
                participants.append(ChatParticipant(name: identityParticipant.displayName, handle: p.handle))
                identityParticipants.append(identityParticipant)
            }

            let isGroup = participants.count > 1
            let identity = ChatIdentity(
                mcpId: "chat\(chat.id)",
                guid: chat.guid,
                explicitName: chat.displayName,
                participants: identityParticipants
            )
```

and `:552` passes `participants: participants` into `ChatResult`. Compare `swift/Sources/iMessageMax/Tools/GetChatDetails.swift:120`:

```swift
                participants: IdentityDisplayFormatter.participants(identity.participants),
```

`swift/Sources/iMessageMax/Utilities/IdentityDisplayFormatter.swift:21-27, 49-58`:

```swift
    static func participants(_ participants: [ChatIdentity.Participant]) -> [ChatParticipant] {
        let unique = uniqueByHandle(participants)
        let names = disambiguatedNames(for: unique)
        return zip(unique, names).map { participant, name in
            ChatParticipant(name: name, handle: participant.handle)
        }
    }
    ...
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
```

So two participants both named "Alex" appear as `Alex (0001)` and `Alex (0002)` in `get_chat_details` but as `Alex`, `Alex` in `find_chat`. `find_chat` also orders by handle where `get_chat_details` orders by display name.

### participantsPreview: one 50-row query per named large chat

`swift/Sources/iMessageMax/Utilities/PreviewResolvers.swift:54-81`:

```swift
    static func participantsPreview(
        db: Database,
        chatId: Int64,
        identity: ChatIdentity
    ) throws -> [String] {
        let participants = identity.participants
        if participants.count <= 4 {
            return IdentityDisplayFormatter.previewNames(selected: participants, allParticipants: participants)
        }

        let selected: [ChatIdentity.Participant]
        if identity.isNamed {
            let recent = try recentParticipantPreviewNames(db: db, chatId: chatId, participants: participants)
            let backfill = prioritizedParticipants(participants).filter { candidate in
                !recent.contains { $0.handle == candidate.handle }
            }
            selected = Array((recent + backfill).prefix(3))
        } else {
            selected = Array(prioritizedParticipants(participants).prefix(3))
        }

        let remaining = max(0, participants.count - selected.count)
        let preview = IdentityDisplayFormatter.previewNames(selected: selected, allParticipants: participants)
        if remaining == 0 {
            return preview
        }
        return preview + ["+\(remaining) more"]
    }
```

`PreviewResolvers.swift:83-117` (`recentParticipantPreviewNames`):

```swift
        let sql = """
            SELECT h.id as sender_handle
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ?
            AND m.associated_message_type = 0
            AND m.is_from_me = 0
            AND h.id IS NOT NULL
            ORDER BY m.date DESC
            LIMIT 50
            """

        let handles = try db.query(sql, params: [chatId]) { row in
            row.string(0)
        }

        var selected: [ChatIdentity.Participant] = []
        var seen: Set<String> = []
        for handle in handles {
            guard let handle, let participant = handleToParticipant[handle], seen.insert(handle).inserted else {
                continue
            }
            selected.append(participant)
            if selected.count == 3 { break }
        }
        return selected
```

Semantics to preserve exactly: the first three *distinct* inbound sender handles among the 50 most recent inbound non-reaction messages, in recency order, then `prioritizedParticipants` backfill (contact-named first, then display name, then handle) for handles not already chosen, then `prefix(3)`.

Callers of `participantsPreview` / `buildSummary`, one call per row in each:
- `ListChats.swift:461-465`
- `FindChat.swift:546-550`
- `GetActiveConversations.swift:284-288`
- `GetUnread.swift:405-409` (via `ChatSummaryBuilder.buildSummary`)
- `SearchInternals.swift:589` (via `buildChatSummary`)

### lastMessagesByChat: attachment types per row

`ChatSummaryQueries.swift:323-331`:

```swift
            let summary = LastMessageSummary(
                from: sender,
                text: try MessagePreviewResolver.messageSummary(
                    db: db,
                    messageId: row.messageId,
                    text: row.text,
                    attributedBody: row.attributedBody,
                    maxLength: previewMaxLength
                ),
```

`PreviewResolvers.swift:4-36`:

```swift
    static func messageSummary(db: Database, messageId: Int64, text: String?, attributedBody: Data?, maxLength: Int) throws -> String {
        if let formatted = SummaryPreviewFormatter.formattedTextPreview(text: text, attributedBody: attributedBody, maxLength: maxLength) {
            return formatted
        }
        return SummaryPreviewFormatter.attachmentPlaceholder(for: try attachmentTypes(db: db, messageId: messageId))
    }

    static func attachmentTypes(db: Database, messageId: Int64) throws -> [AttachmentType] {
        let sql = """
            SELECT a.mime_type, a.uti
            FROM attachment a
            JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = ?
            ORDER BY a.ROWID ASC
            """
        return try db.query(sql, params: [messageId]) { row in
            AttachmentType.from(mimeType: row.string(0), uti: row.string(1))
        }
    }
```

The batched idiom to copy is `GetMessagesInternals.swift:346-380` (`getAttachmentsMap`): placeholders from `messageIds`, one `WHERE maj.message_id IN (...)` query, fold into `[Int: [AttachmentRow]]`.

### Query-count test hook

`Database.queryCountForTesting` (`Database.swift:54`, `nonisolated(unsafe) static var queryCountForTesting: Int?`) increments on every `query` call when non-nil. Existing users:

- `Tests/iMessageMaxTests/FindChatToolTests.swift:39-54` — sets it to 0, runs `find_chat` over 5 chats, asserts `<= 6`.
- `Tests/iMessageMaxTests/SearchToolTests.swift:347-369` — flat search with `includeContext: true`, 20 results, asserts `<= 5`.
- `Tests/iMessageMaxTests/QueryCountTests.swift` — proves the counter increments.

Pattern:

```swift
        Database.queryCountForTesting = 0
        defer { Database.queryCountForTesting = nil }
        ... run the tool ...
        let queryCount = try XCTUnwrap(Database.queryCountForTesting)
        XCTAssertLessThanOrEqual(queryCount, N, "<tool> ran \(queryCount) queries")
```

### Test fixture

`Tests/iMessageMaxTests/ToolTestSupport.swift` — `ToolTestDatabase(name:)` creates a temp SQLite file with `chat`, `handle`, `chat_handle_join`, `message`, `chat_message_join`, `attachment`, `message_attachment_join`. Helpers: `insertHandle(rowId:handle:)`, `insertChat(rowId:guid:displayName:)`, `joinChatHandle(chatId:handleId:)`, `insertMessage(rowId:guid:text:date:isFromMe:isRead:handleId:associatedMessageType:associatedMessageGuid:error:isSent:attributedBody:)`, `joinChatMessage`, `insertAttachment`, `joinMessageAttachment`, `database()`. `makeSeededResolver()` maps `+15550000001` to "Alice Smith", `+15550000002` to "Bob Brown" (see `ToolTestSupport.swift:179`). Existing preview expectations live in `OverviewResponseTests.swift:27-31`, `UnreadCharacterizationTests.swift:148-155`, `ChatSummaryQueriesTests.swift:86-151`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Full suite | `cd swift && swift test` | 0 failures, count ≥ 370 |
| Preview tests | `cd swift && swift test --filter "ChatSummaryQueriesTests\|OverviewResponseTests\|UnreadCharacterizationTests"` | 0 failures |
| Search tests | `cd swift && swift test --filter SearchToolTests` | 0 failures |
| Tool tests | `cd swift && swift test --filter "FindChatToolTests\|ListToolCharacterizationTests\|ChatDetailsToolTests\|ResponseContractTests"` | 0 failures |
| Sleep guard | `cd swift && swift test --filter LaunchdSafetyTests` | 0 failures |
| Old producers gone | `grep -rn "generateChatDisplayName\|displayNameForChat\|func resolveChatName" swift/Sources` | no matches after Step 5 |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Tools/SearchInternals.swift`
- `swift/Sources/iMessageMax/Utilities/PreviewResolvers.swift`
- `swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift`
- `swift/Sources/iMessageMax/Tools/FindChat.swift`
- `swift/Sources/iMessageMax/Tools/ListChats.swift`
- `swift/Sources/iMessageMax/Tools/GetActiveConversations.swift`
- `swift/Sources/iMessageMax/Tools/GetUnread.swift`
- `swift/Sources/iMessageMax/Tools/GetContext.swift`
- `swift/Sources/iMessageMax/Tools/ListAttachments.swift`
- `swift/Sources/iMessageMax/Tools/SendResolution.swift`
- `swift/Sources/iMessageMax/Models/ChatIdentity.swift` (only if a convenience initializer from `[ChatSummaryQueries.Participant]` is added)
- `swift/Tests/iMessageMaxTests/ChatSummaryQueriesTests.swift`
- `swift/Tests/iMessageMaxTests/SearchToolTests.swift`
- `swift/Tests/iMessageMaxTests/FindChatToolTests.swift`
- `swift/Tests/iMessageMaxTests/ListToolCharacterizationTests.swift`
- `swift/Tests/iMessageMaxTests/ChatIdentityTests.swift` (create if no such file exists; check with `ls swift/Tests/iMessageMaxTests | grep -i identity`)

**Out of scope** (do NOT touch, even though they look related):
- `IdentityDisplayFormatter.swift` — its behaviour is the contract; callers move to it, it does not move.
- `DisplayNameGenerator.swift` — the "Unknown Chat" / "and N others" text is part of the response contract.
- `GetChatDetails.swift` — already correct; it is the reference.
- `GetMessagesInternals.swift` — the batched idiom is copied from it, not changed.
- The JSON shape of any response. Field names and types do not change. Name *values* in `search`, `get_context`, `list_attachments`, and `send` for unnamed chats will change (see "Why this matters"); that is intended.
- `SearchInternals.getContextBatch` and `makeExcerpt` — plan 069.
- `.mcp.json` — never touch.

## Git workflow

- Branch: `advisor/068-batched-participants` from current `main`.
- Conventional commits, one per step: `test:`, `perf:`, `refactor:`. Examples from `git log`: `ci: run the suite serially on macos-26`, `docs: record the 060 cleanup-interval follow-up`.
- Do NOT push or open a PR.
- Never commit secrets; none are involved.

Standing rules: never add `Task.sleep` under `swift/Sources` (`LaunchdSafetyTests` enforces it); never touch `.mcp.json`.

## Steps

### Step 1: Characterization tests before any refactor

Write these tests first and confirm they pass against the current code. They pin the behaviour the refactor must keep.

In `swift/Tests/iMessageMaxTests/ChatSummaryQueriesTests.swift` add:

1. `testRecentSenderPreviewKeepsFirstThreeDistinctInboundThenBackfills`: a named chat (`displayName: "Big Group"`) with 6 handles; seed inbound messages so the most recent 50 inbound come from handles 3, 3, 5, 1 in that order (newest first), plus one `is_from_me = 1` message from nobody and one reaction (`associatedMessageType: 2000`) from handle 6 that must be ignored. Expect `participantsPreview` to start with the display names of handles 3, 5, 1 in that order, followed by `"+3 more"`. (If `ChatSummaryQueriesTests.swift:86-151` already covers part of this, extend rather than duplicate; read those three tests first.)
2. `testUnnamedChatPreviewIgnoresRecency`: same fixture with `displayName: nil`; expect the prioritized order (contact-named first, then alphabetical) regardless of message recency.

In `swift/Tests/iMessageMaxTests/SearchToolTests.swift` add:

3. `testGroupedSearchUsesConstantQueriesAcrossUnnamedChats`: 8 unnamed chats, each with 2 handles and one message containing `"batchname"`; run `SearchTool.execute` with `format: "grouped"`, `limit: 20`, `includeContext: false`; assert the response has 8 chats, every `name` is non-empty and none equals `"Unknown Chat"`. Record the query count with the `queryCountForTesting` pattern but assert only `XCTAssertGreaterThan(queryCount, 8)` for now (it documents the N+1; Step 3 flips it). Copy the argument list from `SearchToolTests.swift:351-364` for the other parameters.
4. `testGroupedSearchUnnamedChatIsNotNamed`: one unnamed 2-handle chat; grouped search; the chat entry's `participants_preview` must equal the two display names (this is the branch that `isNamed == true` would change once the chat has more than four participants, so use 6 handles here and assert the preview is the prioritized order, not recency order).

In `swift/Tests/iMessageMaxTests/FindChatToolTests.swift` add:

5. `testFindChatDisambiguatesDuplicateDisplayNames`: two handles `+15550000011` and `+15550000012` whose resolver names are both "Alex Doe" (build a `ContactResolver` seeded the way `makeSeededResolver()` does, adding both; read `ToolTestSupport.swift:179-186` for the seeding API), in one chat; `find_chat` by participant; expect `participants[*].name` to be `["Alex Doe (0011)", "Alex Doe (0012)"]` (whatever `IdentityDisplayFormatter.disambiguator` produces for those handles: read `IdentityDisplayFormatter.swift:60-71` and assert that). This test must FAIL against current code (find_chat skips the disambiguator). Mark it with a comment `// Fails until Step 5.` and keep it in the file; do not skip it.

In `ListToolCharacterizationTests.swift` add:

6. `testListChatsQueryCountIsConstantInRowCount`: 12 named chats, each with 6 handles and 3 inbound messages; `list_chats` with `limit: 12`; assert count with the same pattern, `XCTAssertGreaterThan(queryCount, 12)` for now.

**Verify**: `cd swift && swift test --filter "ChatSummaryQueriesTests|SearchToolTests|FindChatToolTests|ListToolCharacterizationTests"` → exactly 1 failure, `testFindChatDisambiguatesDuplicateDisplayNames`. Everything else passes.

Commit: `test: characterize participant previews, search naming, and find_chat participants`.

### Step 2: Batched recent-senders and attachment-types queries

In `ChatSummaryQueries.swift` add:

```swift
    /// Most-recent inbound sender handles per chat, newest first, at most
    /// `perChatLimit` rows per chat. Reactions and outbound rows excluded.
    static func recentSendersByChat(
        db: Database,
        chatIds: [Int64],
        perChatLimit: Int = 50
    ) throws -> [Int64: [String]]
```

Implementation: one query using a window function (SQLite ≥ 3.25, available on macOS 15):

```sql
SELECT chat_id, sender_handle FROM (
  SELECT cmj.chat_id AS chat_id,
         h.id AS sender_handle,
         ROW_NUMBER() OVER (PARTITION BY cmj.chat_id ORDER BY m.date DESC, m.ROWID DESC) AS rn
  FROM message m
  JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
  LEFT JOIN handle h ON m.handle_id = h.ROWID
  WHERE cmj.chat_id IN (<placeholders>)
    AND m.associated_message_type = 0
    AND m.is_from_me = 0
    AND h.id IS NOT NULL
)
WHERE rn <= ?
ORDER BY chat_id, rn
```

Params: the chat ids, then `perChatLimit`. Fold into `[Int64: [String]]` preserving order. Guard the empty-ids case like `participantsByChat:33`.

In `PreviewResolvers.swift`:

- Add an overload `participantsPreview(chatId:identity:recentSenders: [String]?)` that does what `:54-81` does but takes the handle list instead of running the query. `nil` means "not prefetched" and falls back to the existing query (so callers can migrate one at a time). Move the selection loop from `recentParticipantPreviewNames:107-116` into a pure helper `selectRecent(handles:participants:)` and call it from both paths.
- Add `buildSummary(chatId:identity:recentSenders:)` the same way.
- Add `MessagePreviewResolver.messageSummary(text:attributedBody:maxLength:attachmentTypes: [AttachmentType])` (no `db`, no query) and `attachmentTypesByMessage(db:messageIds:) -> [Int64: [AttachmentType]]` using the `getAttachmentsMap` idiom (`GetMessagesInternals.swift:346-380`), ordered by `a.ROWID ASC` within each message to match `:30`.

In `ChatSummaryQueries.lastMessagesByChat` (`:175+`): after the rows are fetched and before the per-row loop, collect the message ids whose `formattedTextPreview` is nil (or simply all message ids; simpler, one query either way), call `attachmentTypesByMessage`, and pass `attachmentTypes: map[row.messageId] ?? []` into the no-db overload at `:325`.

**Verify**:
- `cd swift && swift build` → exit 0.
- `cd swift && swift test --filter "ChatSummaryQueriesTests|OverviewResponseTests|UnreadCharacterizationTests|ListToolCharacterizationTests"` → 0 failures (the characterization tests from Step 1 still pass; the two `GreaterThan` count tests still pass because callers are unchanged).
- Add to `ChatSummaryQueriesTests.swift`: `testRecentSendersByChatOrdersNewestFirstPerChat` with two chats and interleaved dates; assert per-chat order and that a reaction row is excluded. → passes.

Commit: `perf: batch recent-sender and attachment-type lookups for chat summaries`.

### Step 3: Callers prefetch once per page

For each caller, collect the chat ids that already exist at that point (every one of these tools already has a `chatIds` array for `participantsByChat`), call `recentSendersByChat` once, and pass `recentSenders: map[chatId]` into the new overload:

- `ListChats.swift:461-465`
- `FindChat.swift:546-550` (the `chatIds` array is at `:505-509`)
- `GetActiveConversations.swift:284-288`
- `GetUnread.swift:405-409` (switch to `buildSummary(...recentSenders:)`)

Optimization allowed: only chats with `identity.isNamed && identity.participantCount > 4` need recent senders; filter `chatIds` to those before the query. If no chat qualifies, skip the query entirely (the helper's empty guard handles it).

Now flip the two count tests from Step 1:

- `testListChatsQueryCountIsConstantInRowCount`: `XCTAssertGreaterThan` → `XCTAssertLessThanOrEqual(queryCount, 8, ...)`. Count the queries `list_chats` actually issues for one page (chat page, participants, counts, last messages, last dates, recent senders, totals, attachment types) and set the bound to that number; state the number and the list in the test's comment.
- `FindChatToolTests.swift:54` bound `6`: it should not need raising; if it does, STOP (the batching went wrong).

**Verify**:
- `cd swift && swift test --filter "ListToolCharacterizationTests|FindChatToolTests|OverviewResponseTests|UnreadCharacterizationTests"` → 0 failures except `testFindChatDisambiguatesDuplicateDisplayNames` (still expected to fail until Step 5).
- `grep -rn "recentParticipantPreviewNames(db" swift/Sources` → only the fallback inside `PreviewResolvers.swift` (or no matches if you removed the fallback once every caller migrated; removing it is preferred).

Commit: `perf: prefetch recent senders once per page in list_chats, find_chat, get_active_conversations, get_unread`.

### Step 4: Search prefetches participants, builds identities once, stops passing generated names as explicit

In `SearchInternals.swift`:

1. In both `buildFlatResponse` (around `:187`) and `buildGroupedResponse` (`:256-258`), before the row loop: `let chatIds = Array(Set(rows.map(\.chatId)))`, then `let participantsByChat = try await ChatSummaryQueries.participantsByChat(db: db, chatIds: chatIds, resolver: resolver)`, then build `identityByChat: [Int64: ChatIdentity]` with

```swift
    ChatIdentity(
        mcpId: "chat\(chatId)",
        guid: nil,
        explicitName: row.chatDisplayName,   // the chat's real display_name, or nil
        participants: (participantsByChat[chatId] ?? []).map {
            ChatIdentity.makeParticipant(handle: $0.handle, contactName: $0.name)
        }
    )
```

(`row.chatDisplayName` is the same for every row of a chat; take it from the first row seen.)

2. Flat path `:206-221`: replace the `chatNamesCache` / `generateChatDisplayName` block with `let chatName = identityByChat[row.chatId]?.displayName ?? "Unknown Chat"`.
3. Grouped path `:270-295`: delete the name block and the `chatSummaryCache`; replace `buildChatSummary(...)` with `ChatSummaryBuilder.buildSummary(db: db, chatId: chatId, identity: identity, recentSenders: recentSendersByChat[chatId])` where `recentSendersByChat` is prefetched for the named, >4-participant chats as in Step 3. `explicitName` is now the real display name only, so `isNamed` is correct.
4. Delete `buildChatSummary` (`:568-590`) and `generateChatDisplayName` (`:642-667`). If anything else references them (`grep -rn "buildChatSummary\|generateChatDisplayName" swift/`), migrate those references to the identity map too.

Then flip `testGroupedSearchUsesConstantQueriesAcrossUnnamedChats`: `XCTAssertGreaterThan` → `XCTAssertLessThanOrEqual(queryCount, 4, ...)` (search rows, participants, recent senders (skipped: unnamed), plus whatever `SearchTool.execute` runs before the builder; count it and write the number). The existing `SearchToolTests.swift:369` bound of 5 for flat search must still hold.

**Verify**:
- `cd swift && swift test --filter SearchToolTests` → 0 failures.
- `grep -n "generateChatDisplayName\|func buildChatSummary\|chatNamesCache\|chatSummaryCache" swift/Sources/iMessageMax/Tools/SearchInternals.swift` → no matches.
- Name-shape change check: run `swift test --filter ResponseContractTests` → 0 failures. If any test elsewhere asserted a first-name-only search chat name (`grep -rn '"Alice, Bob"\|"Alice"' swift/Tests` and read the hits), update the expectation to the full display names and say so in the commit body.

Commit: `perf: search builds one ChatIdentity per chat and never passes a generated name as explicit`.

### Step 5: One producer — route get_context, list_attachments, send, and find_chat through ChatIdentity

Add to `ChatIdentity.swift` (inside the struct, near `makeParticipant`):

```swift
    /// Builds an identity from the batched participant rows so every tool
    /// produces the same name for the same chat.
    static func from(
        chatId: Int64,
        guid: String?,
        explicitName: String?,
        rows: [ChatSummaryQueries.Participant]
    ) -> ChatIdentity {
        ChatIdentity(
            mcpId: "chat\(chatId)",
            guid: guid,
            explicitName: explicitName,
            participants: rows.map { makeParticipant(handle: $0.handle, contactName: $0.name) }
        )
    }
```

Then:

- `GetContext.swift:460-481` `displayNameForChat`: body becomes `ChatIdentity.from(chatId:guid:nil, explicitName:, rows: try await ChatSummaryQueries.participants(...)).displayName`. Keep the function name if that is the smallest diff, or inline it at its call site and delete it; either is fine, but the `.sorted { $0.handle < $1.handle }` and the manual `DisplayNameGenerator` call must go.
- `ListAttachments.swift:510-537` `resolveChatName`: same replacement; keep the `cache`.
- `SendResolution.swift:64-90`: build the identity once; `name:` becomes `identity.displayName`; `deliveredTo:` becomes `identity.participants.map(\.displayName)` (order changes from handle-sorted to display-name-sorted; `send` tests that assert `delivered_to` order must be updated, `grep -rn "deliveredTo\|delivered_to" swift/Tests`).
- `FindChat.swift:518-538`: delete the hand-built `participants` array; after constructing `identity`, use `participants: IdentityDisplayFormatter.participants(identity.participants)` at `:552`, exactly as `GetChatDetails.swift:120` does. `isGroup` becomes `identity.participantCount > 1`. Drop the `.sorted { $0.handle < $1.handle }` on `:519` (the identity sorts).

**Verify**:
- `cd swift && swift test` → 0 failures. `testFindChatDisambiguatesDuplicateDisplayNames` now passes; remove its `// Fails until Step 5.` comment.
- `grep -rn "func generateChatDisplayName\|func displayNameForChat\|func resolveChatName" swift/Sources` → no matches (or, if `displayNameForChat` / `resolveChatName` were kept as thin wrappers, `grep -rn "DisplayNameGenerator.fromNames" swift/Sources` → exactly one match, in `ChatIdentity.swift`).
- `grep -rn "sorted { \$0.handle < \$1.handle }" swift/Sources` → no matches.
- `cd swift && swift test --filter LaunchdSafetyTests` → 0 failures.

Commit: `refactor: ChatIdentity is the only chat display-name producer; find_chat uses the shared participant formatter`.

## Test plan

- Step 1 characterization tests (six new tests, one deliberately failing until Step 5).
- Step 2: `testRecentSendersByChatOrdersNewestFirstPerChat` plus an attachment-only last-message test: chat whose most recent message has `text: nil` and one image attachment; `lastMessagesByChat` returns `"[Photo]"` (or whatever `attachmentPlaceholder` returns for `image/jpeg`; read `SummaryPreviewFormatter.attachmentPlaceholder` and assert the real string).
- Steps 3-4 flip two count assertions from `GreaterThan` to `LessThanOrEqual` with a bound derived by counting.
- Structural pattern: `FindChatToolTests.swift:39-54` for query counts; `OverviewResponseTests.swift:27-31` for preview expectations.
- Golden tests expected to move (list them in the final commit body): any `send` test asserting `delivered_to` order; any test asserting a first-name-only chat name from `search`; any `list_attachments` or `get_context` test that asserted a handle-sorted name. `grep -rn '"name"\] as? String\|\.name, "' swift/Tests` before Step 5 and read each hit.
- Final: `cd swift && swift test` → 0 failures, count ≥ 370 + new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift build` exits 0
- [ ] `cd swift && swift test` exits 0 with 0 failures
- [ ] `grep -rn "DisplayNameGenerator.fromNames" swift/Sources` → exactly 1 match, in `Models/ChatIdentity.swift`
- [ ] `grep -rn "generateChatDisplayName\|func buildChatSummary" swift/Sources` → no matches
- [ ] `grep -n "ChatSummaryQueries.participants(" swift/Sources/iMessageMax/Tools/SearchInternals.swift` → no matches
- [ ] `grep -n "IdentityDisplayFormatter.participants(identity.participants)" swift/Sources/iMessageMax/Tools/FindChat.swift` → 1 match
- [ ] `grep -n "func recentSendersByChat\|func attachmentTypesByMessage" swift/Sources/iMessageMax/Utilities/*.swift` → 2 matches
- [ ] `testFindChatDisambiguatesDuplicateDisplayNames`, `testGroupedSearchUsesConstantQueriesAcrossUnnamedChats`, `testListChatsQueryCountIsConstantInRowCount` exist and pass
- [ ] `grep -rn "Task.sleep" swift/Sources` → no matches
- [ ] `git status --porcelain` lists only in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any "Current state" excerpt does not match the live file.
- `Database.queryCountForTesting` does not exist or does not increment (Step 1 cannot be written).
- The window-function query in Step 2 fails on the test fixture with a syntax error (SQLite older than 3.25); report the `sqlite3 --version` and the SQLite library version the test binary links (`swift test` output or `otool -L`). Do not fall back to a per-chat loop silently.
- The `find_chat` bound of 6 in `FindChatToolTests.swift:54` has to be raised to make Step 3 pass.
- The Step 1 characterization test for recent senders fails against *current* code (the documented semantics are wrong and the plan's target is unclear).
- A golden test outside the listed test files changes its expected chat name and you cannot explain the change as "first-name-only or handle-sorted became `ChatIdentity` order".
- `send` integration (`SendResolution`) has a consumer that depends on `deliveredTo` being handle-sorted (search `swift/Sources` for `deliveredTo` uses before changing it).

## Maintenance notes

- **Adding a new tool that returns a chat name**: build a `ChatIdentity` (via `ChatIdentity.from(chatId:guid:explicitName:rows:)`) and read `.displayName`. Do not call `DisplayNameGenerator.fromNames` directly; the done criterion greps for it.
- **Adding a new per-row lookup in a list tool**: it must have a `...ByChat(db:chatIds:)` batched form in `ChatSummaryQueries` and a count test with a bound. The three count tests are the regression net.
- **Reviewer should scrutinize**: the recent-senders window query's tie-break (`m.date DESC, m.ROWID DESC`) versus the old `ORDER BY m.date DESC` with no tie-break; ties are real in chat.db (same-second sends), and the characterization test should include one to pin which wins. The `isNamed` fix in Step 4 changes `participants_preview` for unnamed large chats in grouped search from recency order to prioritized order; that is correct and should be called out in the PR.
- **Deferred**: `ListAttachments.resolveChatName` still runs one participants query per distinct chat (with a cache). Batching it needs the message page's chat ids first; it is a smaller win and can follow. `SearchInternals` context batching and excerpt cost are plan 069.
