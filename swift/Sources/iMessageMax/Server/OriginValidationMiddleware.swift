import Foundation
import Hummingbird
import HTTPTypes
import IMessageMaxContract

/// Validates Origin and Host headers to prevent DNS rebinding attacks.
///
/// Per the MCP specification, servers should validate that requests come from
/// expected origins when using HTTP transport to prevent malicious websites
/// from making requests to the local MCP server.
struct OriginValidationMiddleware<Context: RequestContext>: RouterMiddleware {
    /// The address the server listens on. Requests may name it, or loopback.
    let boundHost: String

    /// Whether to require an Origin header (strict mode)
    let requireOrigin: Bool

    init(boundHost: String = ServiceDefaults.host, requireOrigin: Bool = false) {
        self.boundHost = boundHost
        self.requireOrigin = requireOrigin
    }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if let origin = request.headers[.origin] {
            guard let host = URL(string: origin)?.host,
                HostBindingPolicy.isAllowedRequestHost(host, boundHost: boundHost)
            else {
                return forbidden("Origin not allowed")
            }
        } else if requireOrigin {
            return forbidden("Origin header required")
        }

        // Host validation is mandatory. swift-http-types strips the Host header
        // from HTTPFields and stores it in HTTPRequest.authority (for HTTP/1.1
        // Host and HTTP/2 :authority compatibility).
        guard let authority = request.head.authority ?? request.uri.host,
            HostBindingPolicy.isAllowedRequestHost(Self.hostWithoutPort(authority), boundHost: boundHost)
        else {
            return forbidden("Host not allowed")
        }

        return try await next(request, context)
    }

    /// `[::1]:8080` -> `[::1]`, `localhost:8080` -> `localhost`. A bare IPv6
    /// address (several colons) and a non-numeric suffix are left whole.
    static func hostWithoutPort(_ authority: String) -> String {
        if authority.hasPrefix("[") {
            guard let closeBracket = authority.firstIndex(of: "]") else { return authority }
            return String(authority[...closeBracket])
        }
        guard authority.filter({ $0 == ":" }).count == 1,
            let lastColon = authority.lastIndex(of: ":")
        else { return authority }
        let port = authority[authority.index(after: lastColon)...]
        guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return authority }
        return String(authority[..<lastColon])
    }

    private func forbidden(_ message: String) -> Response {
        Response(
            status: .forbidden,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: JSONRPC.error(id: nil, code: .invalidRequest, message: message)))
        )
    }
}
