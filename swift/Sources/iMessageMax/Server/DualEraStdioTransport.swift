// Sources/iMessageMax/Server/DualEraStdioTransport.swift
//
// Dual-era stdio adapter. ModernDispatcher directly answers modern
// (MCP 2026-07-28) messages, meaning the `server/discover` probe and any
// request carrying per-request `_meta` protocol metadata; they never
// reach the legacy SDK Server. Everything else (the legacy `initialize`
// handshake and session traffic) passes through untouched, so existing
// stdio clients keep their exact wire behavior. `initialize` always stays
// on the legacy lane, no matter what `_meta` it carries, mirroring
// HTTPTransport's era selection.
//
// The modern lane is stateless, so each modern message is dispatched in its
// own child task: the pump loop itself never awaits request handling, only
// parses, routes, yields, and spawns. This keeps a slow `tools/call` (e.g. a
// `send` that polls for ~45s) from blocking legacy session traffic or other
// modern requests behind it. Legacy messages remain strictly ordered via
// `continuation.yield`; modern responses may interleave on stdout by design
// (JSON-RPC ids correlate them).
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
            await withDiscardingTaskGroup { group in
                do {
                    for try await data in upstream {
                        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        if let json,
                            (json["method"] as? String) != "initialize",
                            ModernDispatcher.isModernMessage(json) {
                            // Modern lane is stateless: safe to handle
                            // concurrently. Never block the read loop on a
                            // tool call.
                            group.addTask {
                                let result = await ModernDispatcher.handle(data, transport: "stdio")
                                if let responseData = result.data {
                                    do {
                                        try await base.send(responseData)
                                    } catch {
                                        FileHandle.standardError.write(
                                            Data("[iMessage Max] stdio write failed; response dropped: \(error)\n".utf8)
                                        )
                                    }
                                }
                            }
                            continue
                        }
                        let method = (json?["method"] as? String)
                            ?? (json?["id"] != nil ? "response" : "unknown")
                        let version = (json?["params"] as? [String: Any])?["protocolVersion"] as? String
                            ?? "legacy"
                        FileHandle.standardError.write(
                            Data(
                                "[iMessage Max] era=legacy transport=stdio version=\(ModernDispatcher.sanitizedLogField(version)) method=\(ModernDispatcher.sanitizedLogField(method))\n"
                                    .utf8
                            )
                        )
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
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
