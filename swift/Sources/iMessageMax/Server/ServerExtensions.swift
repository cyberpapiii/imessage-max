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

enum OutputSchema {
    static let object: Value = .object([
        "type": .string("object"),
    ])
}

// MARK: - Tool Handler Registry

/// Registry to hold tool handlers and definitions
final class ToolHandlerRegistry: @unchecked Sendable {
    static let shared = ToolHandlerRegistry()

    private var tools: [String: Tool] = [:]
    private var registrationOrder: [String] = []
    private var handlers: [String: @Sendable ([String: Value]?) async throws -> [Tool.Content]] = [:]
    private let lock = NSLock()
    private var version: Int = 0

    private init() {}

    /// Monotonic catalog version: bumps on every register/reset. Consumers may
    /// cache derived catalog data keyed by this value.
    ///
    /// Correctness of any such cache rests on one invariant: **every mutation
    /// of tool state bumps `version` under the lock**. Any future
    /// unregister/replace must do the same.
    var catalogVersion: Int {
        lock.lock()
        defer { lock.unlock() }
        return version
    }

    func register(
        tool: Tool,
        handler: @escaping @Sendable ([String: Value]?) async throws -> [Tool.Content]
    ) {
        lock.lock()
        defer { lock.unlock() }
        if tools[tool.name] == nil {
            registrationOrder.append(tool.name)
        }
        tools[tool.name] = tool
        handlers[tool.name] = handler
        version += 1
    }

    /// Returns tools in registration order. The MCP 2026-07-28 spec asks for
    /// deterministic `tools/list` ordering so clients can cache catalogs and
    /// LLM prompt caches stay warm.
    func getTools() -> [Tool] {
        lock.lock()
        defer { lock.unlock() }
        return registrationOrder.compactMap { tools[$0] }
    }

    func getHandler(for name: String) -> (@Sendable ([String: Value]?) async throws -> [Tool.Content])? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[name]
    }

    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        tools.removeAll()
        registrationOrder.removeAll()
        handlers.removeAll()
        version += 1
    }
}

// MARK: - Tool Error

/// Error type that tools throw to signal failure with content.
/// The CallTool handler catches this and sets isError: true on the result,
/// letting MCP clients programmatically distinguish errors from success.
struct ToolError: Error {
    let content: [Tool.Content]
}

extension Tool.Content {
    static func plainText(_ text: String) -> Self {
        .text(text: text, annotations: nil, _meta: nil)
    }

    static func plainImage(data: String, mimeType: String) -> Self {
        .image(data: data, mimeType: mimeType, annotations: nil, _meta: nil)
    }
}

// MARK: - Server Extension

extension Server {
    /// Register a tool with the server
    @discardableResult
    nonisolated func registerTool(
        name: String,
        title: String? = nil,
        description: String,
        inputSchema: Value,
        outputSchema: Value? = nil,
        icons: [Icon]? = nil,
        annotations: Tool.Annotations = nil,
        handler: @escaping @Sendable ([String: Value]?) async throws -> [Tool.Content]
    ) -> Self {
        let tool = Tool(
            name: name,
            title: title ?? annotations.title,
            description: description,
            inputSchema: inputSchema,
            annotations: annotations,
            outputSchema: outputSchema,
            icons: icons ?? IconMetadata.toolIcons
        )

        ToolHandlerRegistry.shared.register(tool: tool, handler: handler)

        return self
    }

    /// Register built-in handlers for ListTools and CallTool
    func registerToolHandlers() async {
        // Register ListTools handler
        self.withMethodHandler(ListTools.self) { _ in
            let tools = ToolHandlerRegistry.shared.getTools()
            return ListTools.Result(tools: tools)
        }

        // Register CallTool handler
        self.withMethodHandler(CallTool.self) { params in
            guard let handler = ToolHandlerRegistry.shared.getHandler(for: params.name) else {
                throw MCPError.methodNotFound("Unknown tool: \(params.name)")
            }

            do {
                let content = try await handler(params.arguments)
                return CallTool.Result(
                    content: content,
                    structuredContent: Self.structuredContent(from: content)
                )
            } catch let error as ToolError {
                return CallTool.Result(content: error.content, isError: true)
            } catch let error as MCPError {
                throw error
            } catch {
                return CallTool.Result(
                    content: [
                        .plainText(
                            "Error: \(ClientErrorMessages.internalDetail(error, context: "Tool execution"))"
                        )
                    ],
                    isError: true
                )
            }
        }
    }

    private nonisolated static func structuredContent(from content: [Tool.Content]) -> Value? {
        guard content.count == 1,
            case .text(let text, _, _) = content[0],
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        else {
            return nil
        }

        return structuredValue(from: object)
    }

    /// Builds the same `Value` that decoding the text with `JSONDecoder`
    /// produces, without the decoder.
    ///
    /// Every tool result is serialized twice, once as text and once as
    /// structuredContent, and `Value`'s decoder reaches its case by trying each
    /// one in turn and discarding the failures. That cost about 3.7 ms on a
    /// 5.7 kB response, more than the database work behind it. JSONSerialization
    /// parses the same text in about 0.05 ms and this walks the result once.
    ///
    /// The case choices mirror `Value.init(from:)` exactly: booleans before
    /// numbers, integers before doubles (JSONSerialization flags which one the
    /// text held, the same distinction the decoder makes by trying `Int` first),
    /// and data URLs still become `.data`.
    /// Exposed for the equivalence test that pins this against `JSONDecoder`.
    nonisolated static func structuredValue(from object: Any) -> Value? {
        switch object {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if CFNumberIsFloatType(number) {
                return .double(number.doubleValue)
            }
            guard let int = Int(exactly: number) else {
                return .double(number.doubleValue)
            }
            return .int(int)
        case let string as String:
            if Data.isDataURL(string: string), case let (mimeType, data)? = Data.parseDataURL(string) {
                return .data(mimeType: mimeType, data)
            }
            return .string(string)
        case let array as [Any]:
            var values: [Value] = []
            values.reserveCapacity(array.count)
            for element in array {
                guard let value = structuredValue(from: element) else { return nil }
                values.append(value)
            }
            return .array(values)
        case let dictionary as [String: Any]:
            var values: [String: Value] = [:]
            values.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let value = structuredValue(from: element) else { return nil }
                values[key] = value
            }
            return .object(values)
        default:
            return nil
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
