import Foundation

struct SSEConnectionInfo: Sendable {
    let id: String
    let sessionId: String

    init(
        id: String = UUID().uuidString,
        sessionId: String
    ) {
        self.id = id
        self.sessionId = sessionId
    }
}

struct SSEEvent: Sendable {
    let id: String?
    let event: String?
    let data: String

    init(id: String? = nil, event: String? = nil, data: String) {
        self.id = id
        self.event = event
        self.data = data
    }

    /// Formats the event as an SSE message according to the spec.
    ///
    /// Format:
    /// ```
    /// id: <id>\n
    /// event: <event>\n
    /// data: <data>\n
    /// \n
    /// ```
    func formatted() -> String {
        var result = ""

        if let id = id {
            result += "id: \(id)\n"
        }

        if let event = event {
            result += "event: \(event)\n"
        }

        // Data can be multi-line, each line needs "data: " prefix
        let lines = data.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            result += "data: \(line)\n"
        }

        // Empty line to end the event
        result += "\n"

        return result
    }

    static func keepAlive() -> String {
        return ": keep-alive\n\n"
    }
}

/// Channel for sending events to an SSE connection.
/// Includes automatic keep-alive event generation.
final class SSEChannel: @unchecked Sendable {
    private let continuation: AsyncStream<String>.Continuation

    /// The event stream with interleaved keep-alives.
    ///
    /// Single-consumer: built once at init and consumed exactly once. It used
    /// to be a computed property, so every access spawned a fresh merging task
    /// group over the same single-consumer base stream. A second reader would
    /// silently steal events and leak a task group per access.
    let stream: AsyncStream<String>

    /// - Parameter keepAliveInterval: heartbeat spacing. Production uses the
    ///   30s default; tests shorten it to keep runtime bounded.
    init(keepAliveInterval: Duration = .seconds(30)) {
        var cont: AsyncStream<String>.Continuation!
        let baseStream = AsyncStream<String> { cont = $0 }
        self.continuation = cont

        self.stream = AsyncStream { downstream in
            let merger = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await event in baseStream {
                            downstream.yield(event)
                        }
                        downstream.finish()
                    }

                    // Keep-alive task. AsyncTimeout.sleep is launchd-safe but
                    // non-cancellable, so cancellation lands at the next
                    // interval boundary. That is the accepted plan-019 trade.
                    group.addTask {
                        while !Task.isCancelled {
                            await AsyncTimeout.sleep(keepAliveInterval)
                            if Task.isCancelled { break }
                            downstream.yield(SSEEvent.keepAlive())
                        }
                    }

                    await group.next()
                    group.cancelAll()
                }
            }

            // Client disconnect drops the response-body iterator; stop the
            // merger instead of letting the keep-alive spin on a dead stream.
            downstream.onTermination = { _ in
                merger.cancel()
            }
        }
    }

    func send(_ event: String) {
        continuation.yield(event)
    }

    func close() {
        continuation.finish()
    }
}

actor SSEConnectionManager {
    private var connectionInfo: [String: SSEConnectionInfo] = [:]
    private var channels: [String: SSEChannel] = [:]
    private var sessionConnections: [String: Set<String>] = [:]

    func register(info: SSEConnectionInfo) -> SSEChannel {
        connectionInfo[info.id] = info

        let channel = SSEChannel()
        channels[info.id] = channel

        if sessionConnections[info.sessionId] == nil {
            sessionConnections[info.sessionId] = []
        }
        sessionConnections[info.sessionId]?.insert(info.id)

        return channel
    }

    func unregister(connectionId: String) {
        guard let info = connectionInfo.removeValue(forKey: connectionId) else { return }

        channels[connectionId]?.close()
        channels.removeValue(forKey: connectionId)

        sessionConnections[info.sessionId]?.remove(connectionId)

        if sessionConnections[info.sessionId]?.isEmpty == true {
            sessionConnections.removeValue(forKey: info.sessionId)
        }
    }

    func connectionIds(forSession sessionId: String) -> [String] {
        guard let ids = sessionConnections[sessionId] else { return [] }
        return Array(ids)
    }

    func broadcast(sessionId: String, event: String) {
        guard let connectionIds = sessionConnections[sessionId] else { return }
        for connectionId in connectionIds {
            channels[connectionId]?.send(event)
        }
    }

    func terminateSession(sessionId: String) {
        guard let connectionIds = sessionConnections.removeValue(forKey: sessionId) else { return }
        for connectionId in connectionIds {
            connectionInfo.removeValue(forKey: connectionId)
            channels[connectionId]?.close()
            channels.removeValue(forKey: connectionId)
        }
    }

    var connectionCount: Int {
        connectionInfo.count
    }
}
