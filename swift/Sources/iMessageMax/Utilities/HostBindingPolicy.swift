import Foundation
import IMessageMaxContract

enum HostBindingPolicy {
    static func isLoopback(_ host: String) -> Bool {
        ServiceDefaults.loopbackHosts.contains(host.lowercased())
    }

    static func validationError(host: String, allowExternalBind: Bool) -> String? {
        if isLoopback(host) || allowExternalBind { return nil }
        return """
        Refusing to bind to '\(host)': this would expose iMessage data and the access \
        token to the network over unencrypted HTTP. Use the default \(ServiceDefaults.host), or pass \(ServerOption.allowExternalBind.flag) \
        if you really intend to expose the server.
        """
    }

    static func isAllowedRequestHost(_ host: String, boundHost: String) -> Bool {
        let host = unbracketed(host)
        return isLoopback(host) || host.lowercased() == unbracketed(boundHost).lowercased()
    }

    private static func unbracketed(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }
}
