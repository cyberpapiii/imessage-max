import Foundation
import NIOCore

/// Represents metadata about an SSE connection.
struct SSEConnectionInfo: Sendable {
    /// Unique identifier for this connection
    let id: String

    /// Session ID this connection belongs to
    let sessionId: String

    /// Last event ID received from client (for resumption)
    let lastEventId: String?

    /// When this connection was established
    let connectedAt: Date

    init(
        id: String = UUID().uuidString,
        sessionId: String,
        lastEventId: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.lastEventId = lastEventId
        self.connectedAt = Date()
    }
}

/// Represents a Server-Sent Event to be sent to clients.
struct SSEEvent: Sendable {
    /// Optional event ID for client resumption
    let id: String?

    /// Event type (defaults to "message" if nil)
    let event: String?

    /// Event data (JSON-RPC message)
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

    /// Creates a keep-alive comment (SSE heartbeat)
    static func keepAlive() -> String {
        return ": keep-alive\n\n"
    }
}

/// Channel for sending events to an SSE connection.
/// Includes automatic keep-alive event generation.
final class SSEChannel: @unchecked Sendable {
    private let continuation: AsyncStream<String>.Continuation
    private let _stream: AsyncStream<String>

    /// The event stream with interleaved keep-alives
    var stream: AsyncStream<String> {
        let baseStream = _stream
        return AsyncStream { continuation in
            Task {
                // Merge events with keep-alives
                await withTaskGroup(of: Void.self) { group in
                    // Event forwarding task
                    group.addTask {
                        for await event in baseStream {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    }

                    // Keep-alive task
                    group.addTask {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(30))
                            if Task.isCancelled { break }
                            continuation.yield(SSEEvent.keepAlive())
                        }
                    }

                    // Wait for event stream to finish, then cancel keep-alive
                    await group.next()
                    group.cancelAll()
                }
            }
        }
    }

    init() {
        var cont: AsyncStream<String>.Continuation!
        self._stream = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func send(_ event: String) {
        continuation.yield(event)
    }

    func close() {
        continuation.finish()
    }
}

/// Manages active SSE connections for sessions.
actor SSEConnectionManager {
    /// Connection metadata keyed by connection ID
    private var connectionInfo: [String: SSEConnectionInfo] = [:]

    /// Channels for sending events, keyed by connection ID
    private var channels: [String: SSEChannel] = [:]

    /// Connections grouped by session ID for efficient lookup
    private var sessionConnections: [String: Set<String>] = [:]

    /// Registers a new SSE connection and returns its channel
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

    /// Unregisters an SSE connection
    func unregister(connectionId: String) {
        guard let info = connectionInfo.removeValue(forKey: connectionId) else { return }

        // Close and remove channel
        channels[connectionId]?.close()
        channels.removeValue(forKey: connectionId)

        sessionConnections[info.sessionId]?.remove(connectionId)

        // Clean up empty session entries
        if sessionConnections[info.sessionId]?.isEmpty == true {
            sessionConnections.removeValue(forKey: info.sessionId)
        }
    }

    /// Gets all connection IDs for a session
    func connectionIds(forSession sessionId: String) -> [String] {
        guard let ids = sessionConnections[sessionId] else { return [] }
        return Array(ids)
    }

    /// Sends an event to all connections for a session
    func broadcast(sessionId: String, event: String) {
        guard let connectionIds = sessionConnections[sessionId] else { return }
        for connectionId in connectionIds {
            channels[connectionId]?.send(event)
        }
    }

    /// Sends an event to all connections across all sessions
    func broadcastAll(event: String) {
        for channel in channels.values {
            channel.send(event)
        }
    }

    /// Removes all connections for a session
    func terminateSession(sessionId: String) {
        guard let connectionIds = sessionConnections.removeValue(forKey: sessionId) else { return }
        for connectionId in connectionIds {
            connectionInfo.removeValue(forKey: connectionId)
            channels[connectionId]?.close()
            channels.removeValue(forKey: connectionId)
        }
    }

    /// Returns the count of active connections
    var connectionCount: Int {
        connectionInfo.count
    }

    /// Checks if a session has any active SSE connections
    func hasActiveConnections(forSession sessionId: String) -> Bool {
        guard let connections = sessionConnections[sessionId] else { return false }
        return !connections.isEmpty
    }
}
