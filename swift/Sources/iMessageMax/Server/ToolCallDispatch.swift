import Foundation
import MCP
import Synchronization

enum ToolCallDispatch {

    enum Execution {
        case unknownTool
        case completed(content: [Tool.Content], isError: Bool)
    }

    static func unknownToolError(_ name: String) -> MCPError {
        .methodNotFound("Unknown tool: \(name)")
    }

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

    /// The tools/call requests this process has received from clients other
    /// than the companion. diagnose reports it as `assistant_calls`, which
    /// turns the companion's Try it step green.
    static let assistantCalls = Mutex(0)

    static func execute(
        name: String, arguments: [String: Value]?, lane: Lane, catalog: ToolCatalog, fromCompanion: Bool = false
    ) async -> Execution {
        if !fromCompanion { assistantCalls.withLock { $0 += 1 } }
        let start = ContinuousClock.now
        let (execution, outcome) = await run(name, catalog.handler(named: name), arguments: arguments)
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        let line = "call tool=\(Log.sanitizedField(name)) \(lane.logFields) outcome=\(outcome) ms=\(String(format: "%.1f", ms))"
        Log.info(line)
        return execution
    }

    private static func run(_ name: String, _ handler: ToolHandler?, arguments: [String: Value]?) async -> (Execution, String) {
        guard let handler else {
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
        } catch {
            let outcome =
                Task.isCancelled || Self.isCancellation(error) ? "cancelled"
                : error is ToolFailure ? "tool_error" : "internal_error"
            return (.completed(content: ToolFailure(error, tool: name).content, isError: true), outcome)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case DatabaseError.cancelled = error { return true }
        return false
    }

    static func contentJSON(_ content: [Tool.Content]) -> [[String: Any]] {
        guard let json = JSONRPC.jsonValue(encoding: content) as? [[String: Any]] else {
            Log.error("contentJSON encode failed; returning empty content")
            return []
        }
        return json
    }

    static func structuredContent(from content: [Tool.Content]) -> [String: Any]? {
        guard content.count == 1,
            case .text(let text, _, _) = content[0],
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return object
    }

    static func decodeArguments(_ raw: Any?) -> [String: Value]? {
        guard let raw = raw as? [String: Any] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
            let decoded = try? JSONDecoder().decode([String: Value].self, from: data)
        else { return nil }
        return decoded
    }

    static func resultJSON(content: [Tool.Content], isError: Bool) -> [String: Any] {
        var result: [String: Any] = ["content": contentJSON(content)]
        if !isError, let structured = structuredContent(from: content) {
            result["structuredContent"] = structured
        }
        if isError {
            result["isError"] = true
        }
        return result
    }
}
