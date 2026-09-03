// Sources/iMessageMax/Server/ToolCallDispatch.swift
import Foundation
import MCP

/// The single place a `tools/call` is executed and turned into JSON.
///
/// Both protocol eras answer the same request with the same tool handler and
/// the same result fields, so they share this. Only the envelope around the
/// result differs, and each lane keeps its own.
enum ToolCallDispatch {

    /// A finished call, already rendered as JSON-ready Foundation objects.
    struct Outcome {
        let content: [[String: Any]]
        let structuredContent: Any?
        let isError: Bool
    }

    enum Result {
        /// No handler is registered under that name. The eras report this
        /// differently, so the decision stays with the caller.
        case unknownTool
        case completed(Outcome)
    }

    /// Arguments arrive already decoded: the raw `Any` a JSON parse yields is
    /// not `Sendable`, so it must not cross into the handler's task.
    static func perform(name: String, arguments: [String: Value]?) async -> Result {
        guard let handler = ToolHandlerRegistry.shared.getHandler(for: name) else {
            return .unknownTool
        }

        do {
            let content = try await withTaskCancellationHandler {
                try await handler(arguments)
            } onCancel: {
                Database.interruptActiveQueries()
            }
            return .completed(
                Outcome(
                    content: contentJSON(content),
                    structuredContent: structuredContentJSON(from: content),
                    isError: false
                )
            )
        } catch let error as ToolError {
            return .completed(
                Outcome(content: contentJSON(error.content), structuredContent: nil, isError: true)
            )
        } catch {
            let message = "Error: \(ClientErrorMessages.internalDetail(error, context: "Tool execution"))"
            return .completed(
                Outcome(
                    content: contentJSON([.plainText(message)]),
                    structuredContent: nil,
                    isError: true
                )
            )
        }
    }

    // MARK: - Serialization helpers

    static func contentJSON(_ content: [Tool.Content]) -> [[String: Any]] {
        guard let data = try? JSONEncoder().encode(content),
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            // Shape safety still demands an array, but never silently: an
            // empty content array turns a successful tool call into an
            // empty-content success.
            Log.error("contentJSON encode failed; returning empty content")
            return []
        }
        return json
    }

    /// A single JSON-object text content doubles as structuredContent.
    static func structuredContentJSON(from content: [Tool.Content]) -> Any? {
        guard content.count == 1,
            case .text(let text, _, _) = content[0],
            let json = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        else { return nil }
        return json
    }

    static func decodeArguments(_ raw: Any?) -> [String: Value]? {
        guard let raw = raw as? [String: Any] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
            let decoded = try? JSONDecoder().decode([String: Value].self, from: data)
        else { return nil }
        return decoded
    }

    /// The `result` object both eras put their own envelope around.
    static func resultJSON(_ outcome: Outcome) -> [String: Any] {
        var result: [String: Any] = ["content": outcome.content]
        if let structured = outcome.structuredContent {
            result["structuredContent"] = structured
        }
        if outcome.isError {
            result["isError"] = true
        }
        return result
    }
}
