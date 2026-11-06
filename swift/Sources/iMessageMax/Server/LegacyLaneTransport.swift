import Foundation
import Logging
import MCP

/// The Transport an SDK `Server` runs on, for both legacy-lane connections:
/// the stdio process and each HTTP session. Messages arrive on `inbound`;
/// replies leave through `deliver`, with server icons added to the
/// `initialize` result on the way out.
actor LegacyLaneTransport: Transport {
    /// Required by `Transport`. Diagnostics go through `Log`.
    nonisolated let logger = Logger(label: "imessage-max.legacy", factory: { _ in SwiftLogNoOpLogHandler() })

    private let inbound: AsyncThrowingStream<Data, Error>
    private let deliver: @Sendable (Data) async throws -> Void
    private var connected = true

    init(inbound: AsyncThrowingStream<Data, Error>, deliver: @escaping @Sendable (Data) async throws -> Void) {
        self.inbound = inbound
        self.deliver = deliver
    }

    /// The owner opens the underlying channel before handing this to the SDK.
    func connect() async throws {}

    /// Replies sent after the SDK stops its Server are dropped.
    func disconnect() async {
        connected = false
    }

    func send(_ data: Data) async throws {
        guard connected else { return }
        try await deliver(IconMetadata.injectServerIcons(into: data))
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        inbound
    }
}
