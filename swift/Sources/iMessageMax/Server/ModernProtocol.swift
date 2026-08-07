// Sources/iMessageMax/Server/ModernProtocol.swift
//
// Modern-era (MCP 2026-07-28) adapter. The pinned swift-sdk (0.12.1) speaks
// the legacy initialize/session protocol only, so the stateless per-request
// era is implemented here as a transport-independent dispatcher. Legacy
// traffic never enters this file; era branching happens once at each
// transport boundary (HTTPTransport.handlePost, DualEraStdioTransport).
import Foundation
import MCP

/// Protocol versions served by the modern (stateless, per-request-metadata) lane.
enum ModernProtocolVersion {
    static let current = "2026-07-28"
    static let supported = [current]
}

/// Reserved `_meta` keys defined by MCP 2026-07-28.
enum ModernMetaKey {
    static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    static let clientInfo = "io.modelcontextprotocol/clientInfo"
    static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    static let serverInfo = "io.modelcontextprotocol/serverInfo"
}

/// Outcome of dispatching one modern-era JSON-RPC message.
///
/// `data` is the serialized JSON-RPC response body (nil for accepted
/// notifications, which produce no body). `httpStatus` is the Streamable
/// HTTP status the spec mandates for the outcome; the stdio transport
/// ignores it.
struct ModernDispatchResult {
    let data: Data?
    let httpStatus: Int

    static let accepted = ModernDispatchResult(data: nil, httpStatus: 202)
}

enum ModernDispatcher {
    /// JSON-RPC error codes defined by the 2026-07-28 spec.
    enum ErrorCode {
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
        static let headerMismatch = -32020
        static let unsupportedProtocolVersion = -32022
    }

    /// Cache hints for the required CacheableResult fields. The tool catalog
    /// only changes when the binary is rebuilt; results describe personal
    /// iMessage data, so shared intermediaries must not cache them.
    private static let catalogTTLMs = 3_600_000
    private static let catalogCacheScope = "private"

    /// Detects whether a decoded JSON-RPC message belongs to the modern era:
    /// either `server/discover` (modern-only method, also the stdio
    /// backward-compatibility probe) or any request carrying the reserved
    /// per-request protocolVersion `_meta` key, which legacy clients never send.
    static func isModernMessage(_ json: [String: Any]) -> Bool {
        guard let method = json["method"] as? String else { return false }
        if method == "server/discover" { return true }
        return requestedProtocolVersion(in: json) != nil
    }

    static func requestedProtocolVersion(in json: [String: Any]) -> String? {
        guard let params = json["params"] as? [String: Any],
            let meta = params["_meta"] as? [String: Any]
        else { return nil }
        return meta[ModernMetaKey.protocolVersion] as? String
    }

    /// Decodes the `=?base64?...?=` sentinel format the spec defines for
    /// header values that cannot be carried as plain ASCII.
    static func decodeBase64Sentinel(_ value: String) -> String {
        guard value.hasPrefix("=?base64?"), value.hasSuffix("?="),
            value.count > 11
        else { return value }
        let inner = String(value.dropFirst("=?base64?".count).dropLast("?=".count))
        guard let data = Data(base64Encoded: inner),
            let decoded = String(data: data, encoding: .utf8)
        else { return value }
        return decoded
    }

    /// Dispatches one modern-era message. Performs the transport-independent
    /// validation (required `_meta` fields, version negotiation) and method
    /// routing; HTTP header/body validation happens in HTTPTransport before
    /// this is called. Takes raw `Data` so callers can cross isolation
    /// boundaries without sending non-Sendable JSON dictionaries.
    static func handle(_ requestData: Data, transport: String) async -> ModernDispatchResult {
        guard let json = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return errorResult(
                id: nil,
                code: ErrorCode.invalidRequest,
                message: "Invalid JSON",
                httpStatus: 400
            )
        }
        guard let method = json["method"] as? String else {
            return errorResult(
                id: nil,
                code: ErrorCode.invalidRequest,
                message: "Expected a JSON-RPC request or notification",
                httpStatus: 400
            )
        }

        guard let id = json["id"] else {
            // Notification: accept and ignore. The modern core protocol
            // defines no client-to-server notifications the server must act
            // on here (stdio cancellation passes through the legacy lane).
            return .accepted
        }

        let params = json["params"] as? [String: Any] ?? [:]
        let meta = params["_meta"] as? [String: Any] ?? [:]

        guard let requestedVersion = meta[ModernMetaKey.protocolVersion] as? String else {
            return errorResult(
                id: id,
                code: ErrorCode.invalidParams,
                message: "Missing required _meta field \(ModernMetaKey.protocolVersion)",
                httpStatus: 400
            )
        }

        guard ModernProtocolVersion.supported.contains(requestedVersion) else {
            return errorResult(
                id: id,
                code: ErrorCode.unsupportedProtocolVersion,
                message: "Unsupported protocol version",
                data: [
                    "supported": ModernProtocolVersion.supported,
                    "requested": requestedVersion,
                ],
                httpStatus: 400
            )
        }

        guard meta[ModernMetaKey.clientCapabilities] != nil else {
            return errorResult(
                id: id,
                code: ErrorCode.invalidParams,
                message: "Missing required _meta field \(ModernMetaKey.clientCapabilities)",
                httpStatus: 400
            )
        }

        logEra(transport: transport, version: requestedVersion, method: method, meta: meta)

        switch method {
        case "server/discover":
            return successResult(id: id, result: discoverResult())
        case "tools/list":
            return successResult(id: id, result: toolsListResult())
        case "tools/call":
            return await callTool(id: id, params: params)
        default:
            return errorResult(
                id: id,
                code: ErrorCode.methodNotFound,
                message: "Method not found: \(method)",
                httpStatus: 404
            )
        }
    }

    // MARK: - Method implementations

    private static func discoverResult() -> [String: Any] {
        var serverInfo = serverInfoJSON()
        if let icons = iconsJSON() {
            serverInfo["icons"] = icons
        }
        return [
            "resultType": "complete",
            "supportedVersions": ModernProtocolVersion.supported,
            "capabilities": ["tools": ["listChanged": false]],
            "instructions": Version.instructions,
            "ttlMs": catalogTTLMs,
            "cacheScope": catalogCacheScope,
            "_meta": [ModernMetaKey.serverInfo: serverInfo],
        ]
    }

    private static func toolsListResult() -> [String: Any] {
        var result = completeResult()
        result["tools"] = toolsJSON()
        result["ttlMs"] = catalogTTLMs
        result["cacheScope"] = catalogCacheScope
        return result
    }

    private static func callTool(id: Any, params: [String: Any]) async -> ModernDispatchResult {
        guard let name = params["name"] as? String else {
            return errorResult(
                id: id,
                code: ErrorCode.invalidParams,
                message: "Missing required parameter: name",
                httpStatus: 400
            )
        }

        guard let handler = ToolHandlerRegistry.shared.getHandler(for: name) else {
            return errorResult(
                id: id,
                code: ErrorCode.invalidParams,
                message: "Unknown tool: \(name)",
                httpStatus: 400
            )
        }

        let arguments = decodeArguments(params["arguments"])

        var result = completeResult()
        do {
            let content = try await handler(arguments)
            result["content"] = contentJSON(content)
            if let structured = structuredContentJSON(from: content) {
                result["structuredContent"] = structured
            }
        } catch let error as ToolError {
            result["content"] = contentJSON(error.content)
            result["isError"] = true
        } catch {
            result["content"] = contentJSON([.plainText("Error: \(error.localizedDescription)")])
            result["isError"] = true
        }
        return successResult(id: id, result: result)
    }

    // MARK: - Serialization helpers

    private static func completeResult() -> [String: Any] {
        [
            "resultType": "complete",
            "_meta": [ModernMetaKey.serverInfo: serverInfoJSON()],
        ]
    }

    private static func serverInfoJSON() -> [String: Any] {
        [
            "name": Version.name,
            "title": Version.title,
            "version": Version.current,
        ]
    }

    private static func iconsJSON() -> [[String: Any]]? {
        guard let icons = IconMetadata.icons,
            let data = try? JSONEncoder().encode(icons),
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return json
    }

    private static func toolsJSON() -> [[String: Any]] {
        let tools = ToolHandlerRegistry.shared.getTools()
        guard let data = try? JSONEncoder().encode(tools),
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return json
    }

    private static func contentJSON(_ content: [Tool.Content]) -> [[String: Any]] {
        guard let data = try? JSONEncoder().encode(content),
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return json
    }

    /// Mirrors the legacy CallTool handler: a single JSON-object text content
    /// doubles as structuredContent.
    private static func structuredContentJSON(from content: [Tool.Content]) -> Any? {
        guard content.count == 1,
            case .text(let text, _, _) = content[0],
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return json
    }

    private static func decodeArguments(_ raw: Any?) -> [String: Value]? {
        guard let raw = raw as? [String: Any] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
            let decoded = try? JSONDecoder().decode([String: Value].self, from: data)
        else { return nil }
        return decoded
    }

    private static func successResult(id: Any, result: [String: Any]) -> ModernDispatchResult {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        return ModernDispatchResult(data: serialize(envelope), httpStatus: 200)
    }

    static func errorResult(
        id: Any?,
        code: Int,
        message: String,
        data: [String: Any]? = nil,
        httpStatus: Int
    ) -> ModernDispatchResult {
        var error: [String: Any] = [
            "code": code,
            "message": message,
        ]
        if let data {
            error["data"] = data
        }
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": error,
        ]
        return ModernDispatchResult(data: serialize(envelope), httpStatus: httpStatus)
    }

    private static func serialize(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }

    // MARK: - Observability

    /// One structured stderr line per modern request: requested version,
    /// selected era, transport, peer identity. No arguments or credentials.
    private static func logEra(transport: String, version: String, method: String, meta: [String: Any]) {
        var client = "unknown"
        if let info = meta[ModernMetaKey.clientInfo] as? [String: Any],
            let name = info["name"] as? String {
            let clientVersion = info["version"] as? String ?? "?"
            client = "\(name)/\(clientVersion)"
        }
        FileHandle.standardError.write(
            "[iMessage Max] era=modern transport=\(transport) version=\(version) method=\(method) client=\(client)\n"
                .data(using: .utf8)!
        )
    }
}
