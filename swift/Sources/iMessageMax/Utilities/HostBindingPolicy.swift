import Foundation

enum HostBindingPolicy {
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

    static func isLoopback(_ host: String) -> Bool {
        loopbackHosts.contains(host.lowercased())
    }

    /// nil if binding is allowed; otherwise the validation error message.
    static func validationError(host: String, allowExternalBind: Bool) -> String? {
        if isLoopback(host) || allowExternalBind { return nil }
        return """
        Refusing to bind to '\(host)': this would expose iMessage data to the network \
        without authentication. Use the default 127.0.0.1, or pass --allow-external-bind \
        if you really intend to expose the server.
        """
    }

    /// Whether a request naming `host` (a Host header without its port, or an
    /// Origin's host) may reach a server bound to `boundHost`: a loopback
    /// name, or the bound host itself. Anything else is a DNS-rebinding risk.
    static func isAllowedRequestHost(_ host: String, boundHost: String) -> Bool {
        let host = unbracketed(host)
        return isLoopback(host) || host.lowercased() == unbracketed(boundHost).lowercased()
    }

    private static func unbracketed(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }
}
