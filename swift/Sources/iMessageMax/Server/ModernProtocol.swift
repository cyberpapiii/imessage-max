// Modern-era (MCP 2026-07-28) dispatcher. The pinned swift-sdk speaks the
// legacy initialize/session protocol only, so the stateless per-request era
// is implemented here, independent of transport. Era selection is
// `JSONRPCMessage.era`; HTTP header validation stays in HTTPTransport.
import Foundation
import IMessageMaxContract
import MCP

/// Outcome of one modern-era message.
enum ModernReply {
    /// A notification: nothing to send.
    case accepted
    case result(Data)
    case error(Data, JSONRPCErrorCode)

    var body: Data? {
        switch self {
        case .accepted: nil
        case .result(let data), .error(let data, _): data
        }
    }
}

enum ModernDispatcher {
    /// Cache hints for the required CacheableResult fields. The tool catalog
    /// only changes when the binary is rebuilt; results describe personal
    /// iMessage data, so shared intermediaries must not cache them.
    private static let catalogTTLMs = 3_600_000
    private static let catalogCacheScope = "private"

    /// Validates the required `_meta` fields and the requested version, then
    /// routes the method. `message.era` must be `.modern`.
    static func handle(_ message: JSONRPCMessage, transport: String, catalog: ToolCatalog) async -> ModernReply {
        // A notification: the modern core protocol defines none the server
        // must act on here (stdio cancellation passes through the legacy lane).
        guard let id = message.id, let method = message.method else {
            return .accepted
        }

        let meta = message.meta ?? [:]

        guard let requestedVersion = meta[ModernMetaKey.protocolVersion] as? String else {
            return error(id, .invalidParams, "Missing required _meta field \(ModernMetaKey.protocolVersion)")
        }

        guard ModernProtocol.supported.contains(requestedVersion) else {
            return error(
                id,
                .unsupportedProtocolVersion,
                "Unsupported protocol version",
                data: ["supported": ModernProtocol.supported, "requested": requestedVersion]
            )
        }

        guard meta[ModernMetaKey.clientCapabilities] != nil else {
            return error(id, .invalidParams, "Missing required _meta field \(ModernMetaKey.clientCapabilities)")
        }

        EraLog.modern(message, transport: transport, version: requestedVersion)

        switch method {
        case "server/discover":
            return success(id, discoverResult())
        case "tools/list":
            return success(id, toolsListResult(catalog))
        case "tools/call":
            return await callTool(id: id, message: message, transport: transport, catalog: catalog)
        default:
            return error(id, .methodNotFound, "Method not found: \(method)")
        }
    }

    // MARK: - Method implementations

    private static func discoverResult() -> [String: Any] {
        var serverInfo = Version.serverInfoJSON
        if !IconMetadata.serverIconsJSON.isEmpty {
            serverInfo["icons"] = IconMetadata.serverIconsJSON
        }
        return [
            "resultType": "complete",
            "supportedVersions": ModernProtocol.supported,
            "capabilities": Version.capabilitiesJSON,
            "instructions": Version.instructions,
            "ttlMs": catalogTTLMs,
            "cacheScope": catalogCacheScope,
            "_meta": [ModernMetaKey.serverInfo: serverInfo],
        ]
    }

    private static func toolsListResult(_ catalog: ToolCatalog) -> [String: Any] {
        var result = completeResult()
        result["tools"] = catalog.toolsJSON
        result["ttlMs"] = catalogTTLMs
        result["cacheScope"] = catalogCacheScope
        return result
    }

    private static func callTool(id: Any, message: JSONRPCMessage, transport: String, catalog: ToolCatalog) async -> ModernReply {
        guard let name = message.toolName else {
            return error(id, .invalidParams, "Missing required parameter: name")
        }
        guard !message.hasMalformedToolArguments else {
            return error(id, .invalidParams, "Invalid parameter: arguments must be an object")
        }

        switch await ToolCallDispatch.execute(name: name, arguments: message.toolArguments, lane: .modern(transport: transport), catalog: catalog) {
        case .unknownTool:
            return error(id, .invalidParams, "Unknown tool: \(name)")
        case .completed(let content, let isError):
            var result = completeResult()
            result.merge(ToolCallDispatch.resultJSON(content: content, isError: isError)) { _, new in new }
            return success(id, result)
        }
    }

    // MARK: - Envelopes

    private static func completeResult() -> [String: Any] {
        [
            "resultType": "complete",
            "_meta": [ModernMetaKey.serverInfo: Version.serverInfoJSON],
        ]
    }

    private static func success(_ id: Any, _ result: [String: Any]) -> ModernReply {
        do {
            return .result(try JSONRPC.success(id: id, result: result))
        } catch {
            Log.error("modern serialize failed: \(error)")
            return .result(
                JSONRPC.error(
                    id: JSONRPC.fallbackId(for: id),
                    code: .internalError,
                    message: "Internal error: response serialization failed"
                )
            )
        }
    }

    private static func error(
        _ id: Any,
        _ code: JSONRPCErrorCode,
        _ message: String,
        data: [String: Any]? = nil
    ) -> ModernReply {
        .error(JSONRPC.error(id: id, code: code, message: message, data: data), code)
    }
}
