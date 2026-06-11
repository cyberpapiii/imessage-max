import Foundation

enum HostBindingPolicy {
    static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

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
}
