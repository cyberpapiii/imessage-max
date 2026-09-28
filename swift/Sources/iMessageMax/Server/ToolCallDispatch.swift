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

    /// A finished call before rendering. The legacy stdio lane hands this
    /// straight to the SDK; the HTTP lanes render it with `perform`.
    enum Execution {
        case unknownTool
        case completed(content: [Tool.Content], isError: Bool)
    }

    /// Where a call came in, for its log line.
    enum Lane {
        case legacyHTTP(session: String)
        case legacyStdio
        case modern(transport: String)

        var logFields: String {
            switch self {
            case .legacyHTTP(let session): "lane=legacy-http session=\(session.prefix(8))"
            case .legacyStdio: "lane=legacy-stdio"
            case .modern(let transport): "lane=modern-\(transport)"
            }
        }
    }

    /// Test seam: the most recent call log line.
    nonisolated(unsafe) static var lastCallLogForTesting: String?

    /// Runs the handler. Cancelling the calling task interrupts the SQLite
    /// queries this call opened, and only those.
    ///
    /// Logs one line per call with the tool, lane, outcome and duration. It
    /// never logs arguments: they carry message text and phone numbers.
    static func execute(name: String, arguments: [String: Value]?, lane: Lane) async -> Execution {
        let start = ContinuousClock.now
        let (execution, outcome) = await run(name: name, arguments: arguments)
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        let line = "call tool=\(ModernDispatcher.sanitizedLogField(name)) \(lane.logFields) outcome=\(outcome) ms=\(String(format: "%.1f", ms))"
        lastCallLogForTesting = line
        Log.info(line)
        return execution
    }

    private static func run(name: String, arguments: [String: Value]?) async -> (Execution, String) {
        guard let handler = ToolHandlerRegistry.shared.getHandler(for: name) else {
            return (.unknownTool, "unknown_tool")
        }

        let scope = Database.CallScope()
        do {
            let content = try await Database.$currentCall.withValue(scope) {
                try await withTaskCancellationHandler {
                    try await handler(arguments)
                } onCancel: {
                    Database.interruptActiveQueries(in: scope)
                }
            }
            return (.completed(content: content, isError: false), "ok")
        } catch let error as ToolError {
            return (.completed(content: error.content, isError: true), Task.isCancelled ? "cancelled" : "tool_error")
        } catch {
            let message = "Error: \(ClientErrorMessages.internalDetail(error, context: "Tool execution"))"
            let outcome = Task.isCancelled || Self.isCancellation(error) ? "cancelled" : "internal_error"
            return (.completed(content: [.plainText(message)], isError: true), outcome)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case DatabaseError.cancelled = error { return true }
        return false
    }

    /// Arguments arrive already decoded: the raw `Any` a JSON parse yields is
    /// not `Sendable`, so it must not cross into the handler's task.
    static func perform(name: String, arguments: [String: Value]?, lane: Lane) async -> Result {
        switch await execute(name: name, arguments: arguments, lane: lane) {
        case .unknownTool:
            return .unknownTool
        case .completed(let content, let isError):
            return .completed(
                Outcome(
                    content: contentJSON(content),
                    structuredContent: isError ? nil : structuredContentJSON(from: content),
                    isError: isError
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
