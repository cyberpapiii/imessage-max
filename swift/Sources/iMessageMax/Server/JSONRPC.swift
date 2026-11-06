import Foundation
import IMessageMaxContract
import MCP

enum JSONRPCErrorCode: Int {
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
    case serverError = -32000
    case headerMismatch = -32020
    case unsupportedProtocolVersion = -32022
}

struct JSONRPCMessage: @unchecked Sendable {
    enum Kind { case request, notification, response }
    enum Era { case legacy, modern }

    enum Parsed {
        case message(JSONRPCMessage)
        case batch
        case invalid
    }

    let kind: Kind
    let id: Any?
    let method: String?
    let params: [String: Any]?

    static func parse(_ data: Data) -> Parsed {
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

    var hasMalformedToolArguments: Bool {
        guard let raw = params?["arguments"], !(raw is NSNull) else { return false }
        return !(raw is [String: Any])
    }

    var cancelledRequestKey: String? {
        guard method == "notifications/cancelled" else { return nil }
        return Self.requestKey(for: params?["requestId"])
    }

    var logMethod: String {
        method ?? (kind == .notification ? "notification" : "response")
    }

    var requestKey: String? { Self.requestKey(for: id) }

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
                return "i:\(exact)"
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
    static func success(id: Any, result: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(
        id: Any?,
        code: JSONRPCErrorCode,
        message: String,
        data: [String: Any]? = nil
    ) -> Data {
        envelope(id: id, code: code.rawValue, message: message, data: data)
    }

    static func error(id: Any?, _ error: MCPError) -> Data {
        let encoded = jsonValue(encoding: error) as? [String: Any]
        return envelope(
            id: id,
            code: error.code,
            message: encoded?["message"] as? String ?? error.localizedDescription,
            data: encoded?["data"] as? [String: Any]
        )
    }

    private static func envelope(id: Any?, code: Int, message: String, data: [String: Any]?) -> Data {
        var error = #"{"code":\#(code),"message":\#(fragment(message))"#
        if let data {
            error += #","data":\#(fragment(data))"#
        }
        error += "}"
        return Data(#"{"jsonrpc":"2.0","error":\#(error),"id":\#(fragment(id ?? NSNull()))}"#.utf8)
    }

    static func fallbackId(for id: Any?) -> Any {
        switch id {
        case let string as String: return string
        case let number as NSNumber: return number
        default: return NSNull()
        }
    }

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

enum EraLog {
    static func legacy(_ message: JSONRPCMessage?, transport: String, version: String, session: String? = nil) {
        let method = message?.logMethod ?? "unknown"
        guard method != "tools/call" else { return }
        var line = "era=legacy transport=\(transport) version=\(Log.sanitizedField(version)) method=\(Log.sanitizedField(method))"
        if let session {
            line += " session=\(session.prefix(8))"
        }
        Log.info(line)
    }

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
