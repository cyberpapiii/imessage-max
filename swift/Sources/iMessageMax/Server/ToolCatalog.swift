import Foundation
import MCP

typealias ToolHandler = @Sendable ([String: Value]?) async throws -> [Tool.Content]

struct ToolDefinition: Sendable {
    let tool: Tool
    let handler: ToolHandler

    init(
        name: String,
        description: String,
        inputSchema: Value,
        outputSchema: Value? = nil,
        annotations: Tool.Annotations = nil,
        handler: @escaping ToolHandler
    ) {
        self.tool = Tool(
            name: name,
            title: annotations.title,
            description: description,
            inputSchema: inputSchema,
            annotations: annotations,
            outputSchema: outputSchema,
            icons: IconMetadata.toolIcons
        )
        self.handler = handler
    }
}

final class ToolCatalog: @unchecked Sendable {
    let tools: [Tool]
    let toolsJSON: [[String: Any]]
    private let handlers: [String: ToolHandler]

    init(_ definitions: [ToolDefinition]) {
        tools = definitions.map(\.tool)
        handlers = Dictionary(definitions.map { ($0.tool.name, $0.handler) }) { _, _ in
            preconditionFailure("ToolCatalog: two tools share a name; tools/list would advertise both and only one would run")
        }
        if let json = JSONRPC.jsonValue(encoding: tools) as? [[String: Any]] {
            toolsJSON = json
        } else {
            Log.error("tool catalog encode failed; modern tools/list will be empty")
            toolsJSON = []
        }
    }

    convenience init(
        database: Database,
        resolver: ContactResolver,
        access: MessagesAccess,
        liveInbox: @escaping @Sendable () -> Bool = { false },
        keepAwake: KeepAwake? = nil
    ) {
        self.init([
            FindChatTool.definition(db: database, resolver: resolver),
            GetChatDetailsTool.definition(db: database, resolver: resolver),
            ListChatsTool.definition(db: database, resolver: resolver),
            GetActiveConversations.definition(db: database, resolver: resolver),
            GetMessagesTool.definition(db: database, resolver: resolver),
            GetMessagesSinceTool.definition(db: database, resolver: resolver),
            GetContext.definition(db: database, resolver: resolver),
            SearchTool.definition(db: database, resolver: resolver),
            GetUnread.definition(db: database, resolver: resolver),
            ListAttachments.definition(db: database, resolver: resolver),
            GetAttachment.definition(db: database, resolver: resolver),
            SendTool.definition(db: database, resolver: resolver, access: access),
            DiagnoseTool.definition(db: database, resolver: resolver, access: access, liveInbox: liveInbox, keepAwake: keepAwake),
        ])
    }

    func handler(named name: String) -> ToolHandler? {
        handlers[name]
    }
}
