import Foundation

/// How far a transport attempt got before it stopped. Mirrors the
/// dispatchPhase tracked inside the send AppleScript.
enum DeliveryDisposition: String, Sendable, Encodable, Equatable {
    /// Messages.app returned from `send` without raising an error.
    case completed
    /// The failure happened before the `send` Apple event was issued.
    /// Retrying cannot produce a duplicate.
    case notStarted = "not_started"
    /// The failure happened after the `send` Apple event was issued, or we
    /// cannot tell (timeout, osascript killed, no structured result).
    case mayHaveCompleted = "may_have_completed"

    /// True only when a retry provably cannot duplicate a message.
    var retrySafe: Bool { self == .notStarted }
}

/// A transport failure plus how far it got.
struct SendFailure: Error, LocalizedError, Sendable {
    let error: SendError
    let disposition: DeliveryDisposition

    init(_ error: SendError, disposition: DeliveryDisposition) {
        self.error = error
        self.disposition = disposition
    }

    var errorDescription: String? { error.errorDescription }
}
