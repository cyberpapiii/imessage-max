import Foundation
import MCP

struct WaitForMessagesResponse: Encodable {
    enum Status: String, Encodable {
        /// `messages` holds at least one new message that matches.
        case messages
        /// Nothing matching arrived before the timeout.
        case timeout
        /// The server is stopping or restarting, for example for an update.
        case stopping
    }

    let status: Status
    let page: GetMessagesSinceResponse

    private enum CodingKeys: String, CodingKey { case status }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try page.encode(to: encoder)
    }
}

/// Blocks until a new message that matches arrives, so an agent can wait for
/// a reply in one call instead of polling get_messages_since.
struct WaitForMessagesTool: Sendable {
    /// Codex stops a tool call after 60 s by default, and the HTTP
    /// listener closes a connection idle for 60 s, so a wait stays under both.
    static let timeout = IntArgument(name: "timeout", defaultValue: 30, range: 1...50)
    /// A row with no chat yet stalls the cursor until its chat_message_join
    /// row lands, which does not change MAX(ROWID), so the wait reads again
    /// on this interval instead of waiting for a new row.
    static let stalledRecheck: Duration = .seconds(1)

    let since: GetMessagesSinceTool
    let arrivals: MessageArrivals
    let db: Database
    let resolver: ContactResolver

    init(db: Database, resolver: ContactResolver, arrivals: MessageArrivals) {
        self.db = db
        self.resolver = resolver
        self.arrivals = arrivals
        since = GetMessagesSinceTool(db: db, resolver: resolver)
    }

    static func definition(db: Database, resolver: ContactResolver, arrivals: MessageArrivals) -> ToolDefinition {
        let tool = WaitForMessagesTool(db: db, resolver: resolver, arrivals: arrivals)
        return ToolDefinition(
            name: "wait_for_messages",
            description: """
                Wait for new messages, then return them. Use it to wait for a reply ("tell me when Sam replies") \
                in one call instead of polling get_messages_since. It returns as soon as at least one new message \
                matches the filters, or when timeout seconds pass with none (status "timeout"). By default only \
                messages from other people count; pass include_from_me: true to count my own too. Reactions and \
                old history that syncs in late do not count.
                The response has the same shape as get_messages_since, plus status. To keep waiting, call again \
                with since_rowid set to the returned next_rowid: nothing that arrived in between is missed. Omit \
                since_rowid to wait for messages after this call starts. status "stopping" means the server is \
                restarting or quitting; call again with next_rowid.

                Examples:
                - wait_for_messages(from_person: "Sam"): the next message Sam sends, in any chat
                - wait_for_messages(chat_id: "chat123", since_rowid: 234000): anything new in that chat after the cursor
                """,
            inputSchema: InputSchema.object(
                properties: [
                    "since_rowid": .integer(description: "Exclusive ROWID cursor, such as next_rowid from this tool or get_messages_since. Omit to wait for messages after this call starts."),
                    "chat_id": .string(description: "Only messages in this chat (chat123 or 123)"),
                    "from_person": .string(description: "Only messages from this person: a name, phone number, or email, or 'me'"),
                    "include_from_me": .boolean(description: "Also count messages I send (default false)"),
                    "include_filtered": .boolean(description: "Include chats Messages.app has filtered as junk or unknown senders (default false)"),
                    "timeout": .integer(description: "Seconds to wait (\(timeout.defaultAndMax))"),
                    "limit": .integer(description: "Maximum messages to return (\(GetMessagesSinceTool.limit.defaultAndMax))"),
                ]
            ),
            outputSchema: OutputSchema.object,
            annotations: .init(
                title: "Wait for Messages",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { args in
            try await tool.execute(args: args)
        }
    }

    func execute(args: [String: Value]?) async throws -> [Tool.Content] {
        let response = try await executeImpl(args: args ?? [:])
        return [.plainText(try FormatUtils.encodeJSON(response))]
    }

    private func executeImpl(args: [String: Value]) async throws -> WaitForMessagesResponse {
        let chat = try args["chat_id"]?.stringValue.map { try ChatIdentifier.resolve($0, db: db) }
        let sender = await SenderFilter.resolve(args["from_person"]?.stringValue, resolver: resolver)
        // A message I send in a 1:1 chat carries the other person's handle,
        // so from_person alone would count it as theirs.
        let incomingOnly =
            switch sender {
            case .me: false
            case .some: true
            case nil: !(args["include_from_me"]?.boolValue ?? false)
            }
        let deadline = ContinuousClock.now + .seconds(Self.timeout.read(args))
        let start: Int
        if let rowid = args["since_rowid"]?.intValue, rowid >= 0 {
            start = rowid
        } else {
            start = try await since.currentRowid()
        }
        var query = GetMessagesSinceTool.Query(
            sinceRowid: start,
            scope: ChatScope(named: chat, includeFiltered: args["include_filtered"]?.boolValue ?? false),
            limit: GetMessagesSinceTool.limit.read(args),
            sender: sender,
            incomingOnly: incomingOnly,
            keepLate: false
        )

        var draining = false
        while true {
            let page = try await since.read(query)
            if !page.messages.isEmpty { return Self.response(.messages, page, since: start) }
            if draining { return Self.response(.stopping, page, since: start) }
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero { return Self.response(.timeout, page, since: start) }
            query.sinceRowid = page.nextRowid
            let wait = page.stalled ? min(remaining, Self.stalledRecheck) : remaining
            switch await arrivals.wait(above: Int64(page.currentRowid), timeout: wait) {
            case .arrived, .deadline:
                continue
            case .draining:
                draining = true
            case .cancelled:
                throw CancellationError()
            case .full:
                throw ToolFailure(
                    "too_many_waits",
                    "\(arrivals.capacity) wait_for_messages calls are already waiting. Retry after one returns, or poll get_messages_since."
                )
            }
        }
    }

    /// The page with `since_rowid` set to the cursor the call started from,
    /// so a caller sees the whole range the wait covered.
    private static func response(_ status: WaitForMessagesResponse.Status, _ page: GetMessagesSinceResponse, since start: Int) -> WaitForMessagesResponse {
        var page = page
        page.sinceRowid = start
        return WaitForMessagesResponse(status: status, page: page)
    }
}
