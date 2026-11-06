// The stdio lane. Reads messages from `base` (stdin/stdout in production),
// answers modern (MCP 2026-07-28) ones directly, and forwards everything
// else, unparseable input included, untouched to the SDK Server through
// `legacy`, so existing stdio clients keep their exact wire behavior.
//
// The modern lane is stateless, so each modern message runs in its own child
// task: the read loop only parses, routes, yields, and spawns. A slow
// `tools/call` (a `send` that polls for ~45 s) therefore never blocks legacy
// session traffic or other modern requests. Legacy messages stay strictly
// ordered; modern responses may arrive out of order (JSON-RPC ids
// correlate them). Because the SDK never sees a modern request, a
// `notifications/cancelled` naming one is acted on here, whichever lane the
// notification itself takes.
//
// Every reply goes through one writer task. The SDK's StdioTransport is an
// actor whose `send` suspends when stdout is full, and a second `send` would
// otherwise run in that gap and splice its bytes into the first line.
import Foundation
import MCP

actor DualEraStdio {
    /// Hand this to the SDK Server.
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

    /// Opens `base` and starts routing. Call before starting the SDK Server.
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
                        // Tracked before the next message is read, so a cancel
                        // that follows the request at once still finds it.
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

    /// After input has ended: waits for the read loop, whose task group
    /// holds every modern request still running, then for the writer to
    /// flush their replies, then closes `base`.
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
