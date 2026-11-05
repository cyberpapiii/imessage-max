// Sources/iMessageMax/Server/JSONRPC.swift
//
// The JSON-RPC layer both transports share: one parse per inbound message,
// one era rule, one error-code table, one envelope builder, one era log line.
import Foundation
import MCP

/// JSON-RPC error codes this server sends.
enum JSONRPCErrorCode: Int {
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
    /// Implementation-defined: request timeout, session terminated.
    case serverError = -32000
    /// MCP 2026-07-28: a Streamable HTTP request-metadata header is missing
    /// or disagrees with the body.
    case headerMismatch = -32020
    /// MCP 2026-07-28: the requested `_meta` protocol version is not served.
    case unsupportedProtocolVersion = -32022
}

/// Reserved `_meta` keys defined by MCP 2026-07-28.
enum ModernMetaKey {
    static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    static let clientInfo = "io.modelcontextprotocol/clientInfo"
    static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    static let serverInfo = "io.modelcontextprotocol/serverInfo"
}

/// One inbound JSON-RPC message, decoded once at the transport boundary.
///
/// `@unchecked Sendable`: the fields hold the immutable object graph
/// `JSONSerialization` returns (no mutable-containers option), never mutated.
struct JSONRPCMessage: @unchecked Sendable {
    enum Kind { case request, notification, response }
    enum Era { case legacy, modern }

    enum Parsed {
        case message(JSONRPCMessage)
        case batch
        /// Not a JSON object.
        case invalid
    }

    let kind: Kind
    /// The raw `id`: `NSNull` for an explicit null, nil when absent.
    let id: Any?
    let method: String?
    let params: [String: Any]?

    static func parse(_ data: Data) -> Parsed {
        // Only spaces and tabs are skipped before `[`, as HTTP always did.
        if (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            return .batch
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalid
        }
        return .message(JSONRPCMessage(object))
    }

    init(_ object: [String: Any]) {
        if object["method"] != nil {
            kind = object["id"] != nil ? .request : .notification
        } else if object["result"] != nil || object["error"] != nil {
            kind = .response
        } else {
            kind = .notification
        }
        id = object["id"]
        method = object["method"] as? String
        params = object["params"] as? [String: Any]
    }

    var meta: [String: Any]? { params?["_meta"] as? [String: Any] }

    var modernProtocolVersion: String? { meta?[ModernMetaKey.protocolVersion] as? String }

    /// Era selection, identical on both transports. Only the body decides:
    /// real legacy clients (plug) send `Mcp-Method` and
    /// `MCP-Protocol-Version` on session traffic too, so headers must never
    /// reroute a request. `initialize` always selects the legacy session
    /// lane; `server/discover` or a `_meta` protocol version, which legacy
    /// clients never send, selects the stateless lane.
    var era: Era {
        guard let method, method != "initialize" else { return .legacy }
        return method == "server/discover" || modernProtocolVersion != nil ? .modern : .legacy
    }

    var isInitialize: Bool { method == "initialize" }

    var toolName: String? { params?["name"] as? String }

    var toolArguments: [String: Value]? { ToolCallDispatch.decodeArguments(params?["arguments"]) }

    /// The method for log lines; messages without one are named by kind.
    var logMethod: String {
        method ?? (kind == .notification ? "notification" : "response")
    }

    /// The id as a key for matching a response to its request, or nil when
    /// there is no id or it is not a JSON scalar.
    var requestKey: String? { Self.requestKey(for: id) }

    /// Type-tagged so `1` and `"1"` (both legal, distinct ids) never collide.
    /// Total: never traps, whatever the client sends. Forcing a Double id
    /// through a non-failable Int conversion once let `{"id": 1e300}` on an
    /// unauthenticated POST abort the whole launchd service.
    ///
    /// Branch order matters: `["id": 1]` bridges to NSNumber, and on Apple
    /// platforms both `as? Int` and `as? Double` succeed for integral
    /// NSNumbers, so Int must be tested first to keep `1` in the `i:` space.
    static func requestKey(for id: Any?) -> String? {
        switch id {
        case let string as String:
            return "s:\(string)"
        case let int as Int:
            return "i:\(int)"
        case let double as Double:
            if let exact = Int(exactly: double) {
                return "i:\(exact)"  // 2.0 and 2 are the same JSON number
            }
            return "d:\(double)"
        case is NSNull:
            return "n:null"
        default:
            return nil
        }
    }
}

enum JSONRPC {
    /// `{"jsonrpc":"2.0","id":…,"result":…}`.
    static func success(id: Any, result: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// `{"jsonrpc":"2.0","error":{"code":…,"message":…},"id":…}`, in that
    /// key order. Every value is serialized, never interpolated, so client
    /// text in `message` cannot break out of its string.
    static func error(
        id: Any?,
        code: JSONRPCErrorCode,
        message: String,
        data: [String: Any]? = nil
    ) -> Data {
        var error = #"{"code":\#(code.rawValue),"message":\#(fragment(message))"#
        if let data {
            error += #","data":\#(fragment(data))"#
        }
        error += "}"
        return Data(#"{"jsonrpc":"2.0","error":\#(error),"id":\#(fragment(id ?? NSNull()))}"#.utf8)
    }

    /// The id for an error envelope that stands in for a lost response. A
    /// client correlating by request id would otherwise wait forever on an
    /// `id:null` envelope that looks like it belongs to someone else.
    static func fallbackId(for id: Any?) -> Any {
        switch id {
        case let string as String: return string
        case let number as NSNumber: return number
        default: return NSNull()
        }
    }

    /// An Encodable value as the Foundation object `JSONSerialization` works with.
    static func jsonValue(encoding value: some Encodable) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func fragment(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The per-request era line. Neither form carries arguments or credentials.
enum EraLog {
    /// Legacy traffic. `tools/call` is skipped: ToolCallDispatch logs its own
    /// line with outcome and duration.
    static func legacy(_ message: JSONRPCMessage?, transport: String, version: String, session: String? = nil) {
        let method = message?.logMethod ?? "unknown"
        guard method != "tools/call" else { return }
        var line = "era=legacy transport=\(transport) version=\(Log.sanitizedField(version)) method=\(Log.sanitizedField(method))"
        if let session {
            line += " session=\(session.prefix(8))"
        }
        Log.info(line)
    }

    /// Modern traffic, once the request has passed `_meta` validation, so
    /// `version` is a supported one.
    static func modern(_ message: JSONRPCMessage, transport: String, version: String) {
        var client = "unknown"
        if let info = message.meta?[ModernMetaKey.clientInfo] as? [String: Any],
            let name = info["name"] as? String
        {
            let clientVersion = info["version"] as? String ?? "?"
            client = "\(Log.sanitizedField(name))/\(Log.sanitizedField(clientVersion))"
        }
        Log.info("era=modern transport=\(transport) version=\(version) method=\(Log.sanitizedField(message.logMethod)) client=\(client)")
    }
}
