// Sources/iMessageMax/Server/DualEraStdioTransport.swift
//
// Dual-era stdio adapter. Modern (MCP 2026-07-28) messages — the
// `server/discover` probe and any request carrying per-request `_meta`
// protocol metadata — are answered directly by ModernDispatcher and never
// reach the legacy SDK Server. Everything else (the legacy `initialize`
// handshake and session traffic) passes through untouched, so existing
// stdio clients keep their exact wire behavior.
import Foundation
import Logging
import MCP

actor DualEraStdioTransport: Transport {
    private let base: any Transport
    private let messageStream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var pumpTask: Task<Void, Never>?

    nonisolated let logger: Logger

    init(base: any Transport) {
        self.base = base
        self.logger = Logger(
            label: "mcp.transport.dual-era",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )

        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.messageStream = AsyncThrowingStream<Data, Error> { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws {
        try await base.connect()
        let upstream = await base.receive()
        let base = self.base
        let continuation = self.continuation
        pumpTask = Task {
            do {
                for try await data in upstream {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        ModernDispatcher.isModernMessage(json) {
                        let result = await ModernDispatcher.handle(data, transport: "stdio")
                        if let responseData = result.data {
                            try? await base.send(responseData)
                        }
                        continue
                    }
                    continuation.yield(data)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func disconnect() async {
        pumpTask?.cancel()
        await base.disconnect()
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        try await base.send(data)
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        messageStream
    }
}
