import Foundation
import Hummingbird
import HTTPTypes

/// Middleware for validating Origin headers to prevent DNS rebinding attacks.
///
/// Per the MCP specification, servers should validate that requests come from
/// expected origins when using HTTP transport to prevent malicious websites
/// from making requests to the local MCP server.
struct OriginValidationMiddleware<Context: RequestContext>: RouterMiddleware {
    /// Allowed hosts (e.g., "localhost", "127.0.0.1", "::1")
    let allowedHosts: Set<String>

    /// Whether to require an Origin header (strict mode)
    let requireOrigin: Bool

    init(
        allowedHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]", "::1"],
        requireOrigin: Bool = false
    ) {
        self.allowedHosts = allowedHosts
        self.requireOrigin = requireOrigin
    }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // Check Origin header if present
        if let origin = request.headers[.origin] {
            guard isAllowedOrigin(origin) else {
                return Response(
                    status: .forbidden,
                    headers: [.contentType: "application/json"],
                    body: .init(
                        byteBuffer: .init(string: """
                            {"jsonrpc":"2.0","error":{"code":-32600,"message":"Origin not allowed"},"id":null}
                            """)
                    )
                )
            }
        } else if requireOrigin {
            // Origin header is required but missing — 403 per MCP spec
            return Response(
                status: .forbidden,
                headers: [.contentType: "application/json"],
                body: .init(
                    byteBuffer: .init(string: """
                        {"jsonrpc":"2.0","error":{"code":-32600,"message":"Origin header required"},"id":null}
                        """)
                )
            )
        }

        // Also validate Host header to prevent DNS rebinding
        // Host validation is mandatory — reject if we cannot determine the host
        // Note: swift-http-types strips the Host header from HTTPFields and stores it
        // in HTTPRequest.authority (for HTTP/1.1 Host and HTTP/2 :authority compatibility)
        guard let authority = request.head.authority ?? request.uri.host else {
            return Response(
                status: .forbidden,
                headers: [.contentType: "application/json"],
                body: .init(
                    byteBuffer: .init(string: """
                        {"jsonrpc":"2.0","error":{"code":-32600,"message":"Host not allowed"},"id":null}
                        """)
                )
            )
        }

        // Extract host without port, handling IPv6 bracket notation
        let hostWithoutPort: String
        if authority.hasPrefix("[") {
            // IPv6 bracketed: [::1]:8080 -> [::1]
            if let closeBracket = authority.firstIndex(of: "]") {
                hostWithoutPort = String(authority[authority.startIndex...closeBracket])
            } else {
                hostWithoutPort = authority
            }
        } else if authority.filter({ $0 == ":" }).count > 1 {
            // Bare IPv6 without brackets (e.g., ::1) — contains multiple colons,
            // so don't attempt port stripping which would mangle the address
            hostWithoutPort = authority
        } else {
            // IPv4 or hostname: strip port if present
            // Only strip suffix that looks like :<digits>
            if let lastColon = authority.lastIndex(of: ":") {
                let portCandidate = authority[authority.index(after: lastColon)...]
                if !portCandidate.isEmpty && portCandidate.allSatisfy({ $0.isNumber }) {
                    hostWithoutPort = String(authority[..<lastColon])
                } else {
                    hostWithoutPort = authority
                }
            } else {
                hostWithoutPort = authority
            }
        }

        guard allowedHosts.contains(hostWithoutPort) else {
            return Response(
                status: .forbidden,
                headers: [.contentType: "application/json"],
                body: .init(
                    byteBuffer: .init(string: """
                        {"jsonrpc":"2.0","error":{"code":-32600,"message":"Host not allowed"},"id":null}
                        """)
                )
            )
        }

        return try await next(request, context)
    }

    /// Checks if the origin is in the allowed list
    private func isAllowedOrigin(_ origin: String) -> Bool {
        // Parse origin URL to extract host
        guard let url = URL(string: origin),
            let host = url.host
        else {
            return false
        }

        // Check against allowed hosts (ignore port)
        return allowedHosts.contains(host)
    }
}

extension HTTPField.Name {
    static let origin = HTTPField.Name("Origin")!
}
