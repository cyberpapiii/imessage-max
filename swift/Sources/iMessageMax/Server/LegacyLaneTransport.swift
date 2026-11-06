import Foundation
import Logging
import MCP

actor LegacyLaneTransport: Transport {
    nonisolated let logger = Logger(label: "imessage-max.legacy", factory: { _ in SwiftLogNoOpLogHandler() })

    private let inbound: AsyncThrowingStream<Data, Error>
    private let deliver: @Sendable (Data) async throws -> Void
    private var connected = true

    init(inbound: AsyncThrowingStream<Data, Error>, deliver: @escaping @Sendable (Data) async throws -> Void) {
        self.inbound = inbound
        self.deliver = deliver
    }

    func connect() async throws {}

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
