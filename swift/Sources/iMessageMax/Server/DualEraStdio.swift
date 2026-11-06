// Every reply goes through one writer task. The SDK's StdioTransport is an
// actor whose `send` suspends when stdout is full, and a second `send` would
// otherwise run in that gap and splice its bytes into the first line.
import Foundation
import MCP

actor DualEraStdio {
    nonisolated let legacy: LegacyLaneTransport

    private let base: any Transport
    private let catalog: ToolCatalog
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let outgoing: AsyncStream<Data>
    private let outgoingContinuation: AsyncStream<Data>.Continuation
    private var readLoop: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private let inFlight = InFlightRequests<String>()

    init(base: any Transport, catalog: ToolCatalog) {
        let (inbound, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.base = base
        self.catalog = catalog
        self.continuation = continuation
        let (outgoing, outgoingContinuation) = AsyncStream<Data>.makeStream()
        self.outgoing = outgoing
        self.outgoingContinuation = outgoingContinuation
        self.legacy = LegacyLaneTransport(inbound: inbound) { data in
            outgoingContinuation.yield(data)
        }
    }

    func start() async throws {
        try await base.connect()
        let upstream = await base.receive()
        let base = self.base
        let catalog = self.catalog
        let continuation = self.continuation
        let outgoing = self.outgoing
        let outgoingContinuation = self.outgoingContinuation
        let inFlight = self.inFlight
        writer = Task {
            for await data in outgoing {
                do {
                    try await base.send(data)
                } catch {
                    Log.error("stdio write failed; response dropped: \(error)")
                }
            }
        }
        readLoop = Task {
            await withDiscardingTaskGroup { group in
                do {
                    for try await data in upstream {
                        let message: JSONRPCMessage? =
                            if case .message(let message) = JSONRPCMessage.parse(data) { message } else { nil }
                        if let cancelled = message?.cancelledRequestKey {
                            inFlight.cancel(cancelled)
                        }
                        guard let message, message.era == .modern else {
                            EraLog.legacy(
                                message,
                                transport: "stdio",
                                version: message?.params?["protocolVersion"] as? String ?? "legacy"
                            )
                            continuation.yield(data)
                            continue
                        }
                        let call = inFlight.start(message.kind == .request ? message.requestKey : nil) {
                            await ModernDispatcher.handle(message, transport: "stdio", catalog: catalog)
                        }
                        group.addTask {
                            if let response = await inFlight.finish(call).body {
                                outgoingContinuation.yield(response)
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

    func drain() async {
        await readLoop?.value
        outgoingContinuation.finish()
        await writer?.value
        await base.disconnect()
    }

    func stop() async {
        readLoop?.cancel()
        outgoingContinuation.finish()
        await writer?.value
        await base.disconnect()
        continuation.finish()
    }
}
