import Foundation
import MCP

enum ToolRegistry {
    static func registerAll(on server: Server, db: Database, resolver: ContactResolver) {
        // Register the MCP method handlers for tools
        server.registerToolHandlers()

        // Register individual tools
        FindChatTool.register(on: server, database: db, resolver: resolver)
    }

    // MARK: - Search Tool Registration

    private static func registerSearchTool(on server: Server, db: Database, resolver: ContactResolver) {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "query": .object([
                    "type": "string",
                    "description": "Text to search for (optional if filters provided)"
                ]),
                "from_person": .object([
                    "type": "string",
                    "description": "Filter to messages from this person (or \"me\")"
                ]),
                "in_chat": .object([
                    "type": "string",
                    "description": "Chat ID to search within (e.g., \"chat123\")"
                ]),
                "is_group": .object([
                    "type": "boolean",
                    "description": "True for groups only, False for DMs only"
                ]),
                "has": .object([
                    "type": "string",
                    "description": "Content type filter",
                    "enum": ["link", "image", "video", "attachment"]
                ]),
                "since": .object([
                    "type": "string",
                    "description": "Time bound (ISO, relative like \"24h\", or natural like \"yesterday\")"
                ]),
                "before": .object([
                    "type": "string",
                    "description": "Upper time bound"
                ]),
                "limit": .object([
                    "type": "integer",
                    "description": "Max results (default 20, max 100)",
                    "default": .int(20)
                ]),
                "sort": .object([
                    "type": "string",
                    "description": "Sort order",
                    "enum": ["recent_first", "oldest_first"],
                    "default": "recent_first"
                ]),
                "format": .object([
                    "type": "string",
                    "description": "Response format",
                    "enum": ["flat", "grouped_by_chat"],
                    "default": "flat"
                ]),
                "include_context": .object([
                    "type": "boolean",
                    "description": "Include messages before/after each result",
                    "default": false
                ]),
                "unanswered": .object([
                    "type": "boolean",
                    "description": "Only return messages from me that didn't receive a reply",
                    "default": false
                ]),
                "unanswered_hours": .object([
                    "type": "integer",
                    "description": "Window in hours to check for replies (default 24)",
                    "default": .int(24)
                ])
            ]),
            "additionalProperties": false
        ])

        server.registerTool(
            name: "search",
            description: """
                Full-text search across messages with advanced filtering.

                Examples:
                - search(query: "dinner plans") - find messages containing "dinner plans"
                - search(from_person: "me", since: "7d") - my messages from last week
                - search(has: "link", in_chat: "chat123") - links in a specific chat
                - search(unanswered: true) - questions I sent without replies
                """,
            inputSchema: inputSchema,
            annotations: Tool.Annotations(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            // Extract parameters
            let query = arguments?["query"]?.stringValue
            let fromPerson = arguments?["from_person"]?.stringValue
            let inChat = arguments?["in_chat"]?.stringValue
            let isGroup = arguments?["is_group"]?.boolValue
            let has = arguments?["has"]?.stringValue
            let since = arguments?["since"]?.stringValue
            let before = arguments?["before"]?.stringValue
            let limit = arguments?["limit"]?.intValue ?? 20
            let sort = arguments?["sort"]?.stringValue ?? "recent_first"
            let format = arguments?["format"]?.stringValue ?? "flat"
            let includeContext = arguments?["include_context"]?.boolValue ?? false
            let unanswered = arguments?["unanswered"]?.boolValue ?? false
            let unansweredHours = arguments?["unanswered_hours"]?.intValue ?? 24

            let result = await SearchTool.execute(
                query: query,
                fromPerson: fromPerson,
                inChat: inChat,
                isGroup: isGroup,
                has: has,
                since: since,
                before: before,
                limit: limit,
                sort: sort,
                format: format,
                includeContext: includeContext,
                unanswered: unanswered,
                unansweredHours: unansweredHours,
                db: db,
                resolver: resolver
            )

            switch result {
            case .success(let json):
                return [.text(json)]
            case .failure(let error):
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let errorJson = try encoder.encode(error)
                return [.text(String(data: errorJson, encoding: .utf8) ?? "{}")]
            }
        }
    }
}

// MARK: - Tool Schema Types

/// Schema type for defining tool input properties
indirect enum SchemaType {
    case string(description: String, enumValues: [String]? = nil)
    case integer(description: String)
    case number(description: String)
    case boolean(description: String)
    case array(description: String, items: SchemaType)
    case object(description: String, properties: [String: SchemaType])

    func toValue() -> Value {
        switch self {
        case .string(let desc, let enumVals):
            var obj: [String: Value] = [
                "type": "string",
                "description": .string(desc),
            ]
            if let vals = enumVals {
                obj["enum"] = .array(vals.map { .string($0) })
            }
            return .object(obj)

        case .integer(let desc):
            return .object([
                "type": "integer",
                "description": .string(desc),
            ])

        case .number(let desc):
            return .object([
                "type": "number",
                "description": .string(desc),
            ])

        case .boolean(let desc):
            return .object([
                "type": "boolean",
                "description": .string(desc),
            ])

        case .array(let desc, let items):
            return .object([
                "type": "array",
                "description": .string(desc),
                "items": items.toValue(),
            ])

        case .object(let desc, let props):
            var propsValue: [String: Value] = [:]
            for (key, val) in props {
                propsValue[key] = val.toValue()
            }
            return .object([
                "type": "object",
                "description": .string(desc),
                "properties": .object(propsValue),
            ])
        }
    }
}

/// Input schema builder for tools
enum InputSchema {
    static func object(
        properties: [String: SchemaType],
        required: [String] = []
    ) -> Value {
        var propsValue: [String: Value] = [:]
        for (key, schemaType) in properties {
            propsValue[key] = schemaType.toValue()
        }

        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(propsValue),
        ]

        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }

        return .object(schema)
    }
}

// MARK: - Tool Handler Registry

/// Registry to hold tool handlers and definitions
actor ToolHandlerRegistry {
    static let shared = ToolHandlerRegistry()

    private var tools: [String: Tool] = [:]
    private var handlers: [String: @Sendable ([String: Value]?) async throws -> [Tool.Content]] = [:]

    private init() {}

    func register(
        tool: Tool,
        handler: @escaping @Sendable ([String: Value]?) async throws -> [Tool.Content]
    ) {
        tools[tool.name] = tool
        handlers[tool.name] = handler
    }

    func getTools() -> [Tool] {
        Array(tools.values)
    }

    func getHandler(for name: String) -> (@Sendable ([String: Value]?) async throws -> [Tool.Content])? {
        handlers[name]
    }
}

// MARK: - Server Extension

extension Server {
    /// Register a tool with the server
    @discardableResult
    nonisolated func registerTool(
        name: String,
        description: String,
        inputSchema: Value,
        annotations: Tool.Annotations = nil,
        handler: @escaping @Sendable ([String: Value]?) async throws -> [Tool.Content]
    ) -> Self {
        let tool = Tool(
            name: name,
            description: description,
            inputSchema: inputSchema,
            annotations: annotations
        )

        Task {
            await ToolHandlerRegistry.shared.register(tool: tool, handler: handler)
        }

        return self
    }

    /// Register built-in handlers for ListTools and CallTool
    nonisolated func registerToolHandlers() {
        // Register ListTools handler
        withMethodHandler(ListTools.self) { _ in
            let tools = await ToolHandlerRegistry.shared.getTools()
            return ListTools.Result(tools: tools)
        }

        // Register CallTool handler
        withMethodHandler(CallTool.self) { params in
            guard let handler = await ToolHandlerRegistry.shared.getHandler(for: params.name) else {
                throw MCPError.methodNotFound("Unknown tool: \(params.name)")
            }

            do {
                let content = try await handler(params.arguments)
                return CallTool.Result(content: content)
            } catch let error as MCPError {
                throw error
            } catch {
                return CallTool.Result(
                    content: [.text("Error: \(error.localizedDescription)")],
                    isError: true
                )
            }
        }
    }
}
