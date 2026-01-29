// Sources/iMessageMax/Server/ServerExtensions.swift
import Foundation
import MCP

// MARK: - Tool Schema Types

/// Schema type for defining tool input properties using struct-based pattern
struct SchemaType {
    private let _toValue: () -> Value

    private init(_ toValue: @escaping () -> Value) {
        self._toValue = toValue
    }

    func toValue() -> Value {
        _toValue()
    }

    static func string(description: String, enumValues: [String]? = nil) -> SchemaType {
        SchemaType {
            var obj: [String: Value] = [
                "type": "string",
                "description": .string(description),
            ]
            if let vals = enumValues {
                obj["enum"] = .array(vals.map { .string($0) })
            }
            return .object(obj)
        }
    }

    static func integer(description: String) -> SchemaType {
        SchemaType {
            .object([
                "type": "integer",
                "description": .string(description),
            ])
        }
    }

    static func number(description: String) -> SchemaType {
        SchemaType {
            .object([
                "type": "number",
                "description": .string(description),
            ])
        }
    }

    static func boolean(description: String) -> SchemaType {
        SchemaType {
            .object([
                "type": "boolean",
                "description": .string(description),
            ])
        }
    }

    static func array(description: String, items: SchemaType) -> SchemaType {
        SchemaType {
            .object([
                "type": "array",
                "description": .string(description),
                "items": items.toValue(),
            ])
        }
    }

    static func object(description: String, properties: [String: SchemaType]) -> SchemaType {
        SchemaType {
            var propsValue: [String: Value] = [:]
            for (key, val) in properties {
                propsValue[key] = val.toValue()
            }
            return .object([
                "type": "object",
                "description": .string(description),
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
        Task {
            // Register ListTools handler
            await self.withMethodHandler(ListTools.self) { _ in
                let tools = await ToolHandlerRegistry.shared.getTools()
                return ListTools.Result(tools: tools)
            }

            // Register CallTool handler
            await self.withMethodHandler(CallTool.self) { params in
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
}

// MARK: - Value Extension

extension Value {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [Value]? {
        if case .array(let a) = self { return a }
        return nil
    }
}
