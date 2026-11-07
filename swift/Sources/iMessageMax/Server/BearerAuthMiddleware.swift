import Foundation
import Hummingbird
import HTTPTypes

/// Refuses every request that lacks `Authorization: Bearer <token>`, before
/// any route reads the body. Hummingbird applies router middleware only to
/// routes registered after it, so it must be added before every route.
/// Origin validation runs first, so a web page that probes the port gets a
/// 403 and adds no `auth=rejected` line to the log.
struct BearerAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    static var fix: String { "Open iMessage Max and choose Connect, or copy the token from the app." }

    let token: AccessToken

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let authorization = request.headers[.authorization]
        guard token.authorizes(authorization) else {
            Log.warning(Self.rejectionLine(request, presented: authorization != nil))
            return unauthorized(presented: authorization != nil)
        }
        return try await next(request, context)
    }

    /// Every field comes from the client, so each is cut down to a short
    /// run of safe characters. The Authorization value is never logged.
    static func rejectionLine(_ request: Request, presented: Bool) -> String {
        var line = "auth=rejected reason=\(presented ? "invalid_token" : "missing_token")"
        line += " http=\(loggable(request.method.rawValue, pathCharacters))"
        line += " path=\(loggable(request.uri.path, pathCharacters))"
        if let method = request.headers[.mcpMethod] {
            line += " method=\(loggable(method, methodCharacters))"
        }
        return line
    }

    /// MCP method names are lowercase words joined by `/` and `_`. Keeping
    /// only those characters keeps a whole base64url token out of the log.
    private static var methodCharacters: CharacterSet { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz/_") }
    private static var pathCharacters: CharacterSet { CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_.-") }

    private static func loggable(_ value: String, _ allowed: CharacterSet) -> String {
        let kept = String(String.UnicodeScalarView(value.unicodeScalars.filter(allowed.contains).prefix(64)))
        return kept.isEmpty ? "-" : kept
    }

    private func unauthorized(presented: Bool) -> Response {
        Response(
            status: .unauthorized,
            headers: [
                .contentType: "application/json",
                .wwwAuthenticate: presented ? #"Bearer realm="imessage-max", error="invalid_token""# : #"Bearer realm="imessage-max""#,
            ],
            body: .init(byteBuffer: ByteBuffer(bytes: JSONRPC.error(
                id: nil, code: .invalidRequest, message: "Unauthorized. \(Self.fix)")))
        )
    }
}
