// Sources/iMessageMax/Server/DualEraStdio.swift
//
// The stdio lane. Reads messages from `base` (stdin/stdout in production),
// answers modern (MCP 2026-07-28) ones directly, and forwards everything
// else, unparseable input included, untouched to the SDK Server through
// `legacy`, so existing stdio clients keep their exact wire behavior.
//
// The modern lane is stateless, so each modern message runs in its own child
// task: the read loop only parses, routes, yields, and spawns. A slow
// `tools/call` (a `send` that polls for ~45 s) therefore never blocks legacy
// session traffic or other modern requests. Legacy messages stay strictly
// ordered; modern responses may interleave on stdout (JSON-RPC ids
// correlate them).
import Foundation
import MCP

actor DualEraStdio {
    /// Hand this to the SDK Server.
    nonisolated let legacy: LegacyLaneTransport

    private let base: any Transport
    private let catalog: ToolCatalog
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var readLoop: Task<Void, Never>?

    init(base: any Transport, catalog: ToolCatalog) {
        let (inbound, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.base = base
        self.catalog = catalog
        self.continuation = continuation
        self.legacy = LegacyLaneTransport(inbound: inbound) { data in
            try await base.send(data)
        }
    }

    /// Opens `base` and starts routing. Call before starting the SDK Server.
    func start() async throws {
        try await base.connect()
        let upstream = await base.receive()
        let base = self.base
        let catalog = self.catalog
        let continuation = self.continuation
        readLoop = Task {
            await withDiscardingTaskGroup { group in
                do {
                    for try await data in upstream {
                        let message: JSONRPCMessage? =
                            if case .message(let message) = JSONRPCMessage.parse(data) { message } else { nil }
                        guard let message, message.era == .modern else {
                            EraLog.legacy(
                                message,
                                transport: "stdio",
                                version: message?.params?["protocolVersion"] as? String ?? "legacy"
                            )
                            continuation.yield(data)
                            continue
                        }
                        group.addTask {
                            guard let response = await ModernDispatcher.handle(message, transport: "stdio", catalog: catalog).body else {
                                return
                            }
                            do {
                                try await base.send(response)
                            } catch {
                                Log.error("stdio write failed; response dropped: \(error)")
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func stop() async {
        readLoop?.cancel()
        await base.disconnect()
        continuation.finish()
    }
}
