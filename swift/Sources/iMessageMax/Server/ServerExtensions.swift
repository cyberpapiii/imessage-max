import Foundation
import MCP
import Synchronization

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

extension Tool.Content {
    static func plainText(_ text: String) -> Self {
        .text(text: text, annotations: nil, _meta: nil)
    }

    static func plainImage(data: String, mimeType: String) -> Self {
        .image(data: data, mimeType: mimeType, annotations: nil, _meta: nil)
    }
}

extension Server {
    func registerToolHandlers(_ catalog: ToolCatalog) async {
        self.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: catalog.tools)
        }

        self.withMethodHandler(CallTool.self) { params in
            switch await ToolCallDispatch.execute(name: params.name, arguments: params.arguments, lane: .legacyStdio, catalog: catalog) {
            case .unknownTool:
                throw MCPError.methodNotFound("Unknown tool: \(params.name)")
            case .completed(let content, isError: true):
                return CallTool.Result(content: content, isError: true)
            case .completed(let content, isError: false):
                return CallTool.Result(
                    content: content,
                    structuredContent: ToolCallDispatch.structuredContent(from: content).flatMap(Self.structuredValue(from:))
                )
            }
        }
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
