import Foundation
import MCP

/// A tool's error answer: sent with `isError: true` and a JSON body that
/// carries at least `error` (a stable code) and `message`.
struct ToolFailure: Error {
    let code: String
    let body: any Encodable & Sendable

    init(_ code: String, _ message: String) {
        self.code = code
        self.body = Body(error: code, message: message)
    }

    /// For error shapes with fields beyond `error` and `message`.
    init(code: String, body: some Encodable & Sendable) {
        self.code = code
        self.body = body
    }

    static func chatNotFound(_ chatId: String) -> ToolFailure {
        ToolFailure("chat_not_found", ClientErrorMessages.chatNotFound(chatId))
    }

    /// The answer for an error a tool let escape. Database errors keep their
    /// codes; anything else is logged and reported without its description,
    /// which can embed filesystem paths.
    init(_ error: any Error, tool: String) {
        switch error {
        case let failure as ToolFailure:
            self = failure
        case let dbError as DatabaseError:
            self.init(dbError.clientCode, dbError.clientMessage(context: tool))
        default:
            Log.error("\(tool): \(error.localizedDescription)")
            self.init("internal_error", ClientErrorMessages.internalError)
        }
    }

    var content: [Tool.Content] {
        do {
            return [.plainText(try FormatUtils.encodeJSON(body))]
        } catch {
            Log.error("\(code): error body failed to encode: \(error)")
            return [.plainText(#"{"error":"internal_error","message":"\#(ClientErrorMessages.internalError)"}"#)]
        }
    }

    private struct Body: Encodable, Sendable {
        let error: String
        let message: String
    }
}
