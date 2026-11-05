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

/// The tools this process serves, built once at startup and handed to every
/// lane (legacy stdio, legacy HTTP sessions, the modern dispatcher).
final class ToolCatalog: @unchecked Sendable {
    /// In registration order: MCP 2026-07-28 asks for a deterministic
    /// `tools/list` so client and prompt caches stay warm.
    let tools: [Tool]
    /// `tools` as JSON objects for the modern lane, which advertises a
    /// one-hour catalog TTL and should not re-encode on every request.
    let toolsJSON: [[String: Any]]
    private let handlers: [String: ToolHandler]

    init(_ definitions: [ToolDefinition]) {
        tools = definitions.map(\.tool)
        handlers = Dictionary(definitions.map { ($0.tool.name, $0.handler) }) { _, last in last }
        if let data = try? JSONEncoder().encode(tools),
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        {
            toolsJSON = json
        } else {
            Log.error("tool catalog encode failed; modern tools/list will be empty")
            toolsJSON = []
        }
    }

    convenience init(database: Database, resolver: ContactResolver) {
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
            SendTool.definition(db: database, resolver: resolver),
            DiagnoseTool.definition(db: database, resolver: resolver),
        ])
    }

    func handler(named name: String) -> ToolHandler? {
        handlers[name]
    }
}
