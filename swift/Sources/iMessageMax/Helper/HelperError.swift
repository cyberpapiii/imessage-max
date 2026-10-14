import Foundation

enum HelperError: Error, Equatable {
    case notConnected
    case timeout
    case protocolMismatch(expected: Int, got: Int)
    case idMismatch(expected: String, got: String)
    case malformedResponse(String)
    case remote(code: String, message: String)
}
