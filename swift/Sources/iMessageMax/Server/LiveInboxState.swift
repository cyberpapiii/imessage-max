import Synchronization

enum LiveInboxState {
    private static let running = Mutex(false)

    static func set(running value: Bool) {
        running.withLock { $0 = value }
    }

    static var isRunning: Bool {
        running.withLock { $0 }
    }
}
