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

    func formatted() -> String {
        var result = ""

        if let id = id {
            result += "id: \(id)\n"
        }

        if let event = event {
            result += "event: \(event)\n"
        }

        let lines = data.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            result += "data: \(line)\n"
        }

        result += "\n"

        return result
    }

    static func keepAlive() -> String {
        return ": keep-alive\n\n"
    }
}

final class SSEChannel: @unchecked Sendable {
    private let continuation: AsyncStream<String>.Continuation

    let stream: AsyncStream<String>

    init(keepAliveInterval: Duration) {
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
    private let keepAliveInterval: Duration
    private var isClosed = false

    init(keepAliveInterval: Duration) {
        self.keepAliveInterval = keepAliveInterval
    }

    func register(info: SSEConnectionInfo) -> SSEChannel {
        let channel = SSEChannel(keepAliveInterval: keepAliveInterval)
        guard !isClosed else {
            channel.close()
            return channel
        }
        connectionInfo[info.id] = info
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

    func closeAll() {
        isClosed = true
        for channel in channels.values {
            channel.close()
        }
        channels.removeAll()
        connectionInfo.removeAll()
        sessionConnections.removeAll()
    }

    var connectionCount: Int {
        connectionInfo.count
    }
}
