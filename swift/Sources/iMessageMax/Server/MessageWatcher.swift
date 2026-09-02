import Darwin
import Foundation

/// Watches chat.db (and its -wal/-shm siblings and directory) with kqueue
/// through DispatchSource, debounces to one poll per `debounce`, and always
/// runs a fallback poll every `fallbackInterval` that also re-checks file
/// identities (st_dev, st_ino) and re-registers sources after rotation.
/// Fires `onNewRows(maxRowid)` when SELECT MAX(ROWID) FROM message grows.
/// No Task.sleep: all timing is DispatchSourceTimer on a private queue.
final class MessageWatcher: @unchecked Sendable {
    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init?(path: String) {
            var st = stat()
            guard stat(path, &st) == 0 else { return nil }
            self.device = UInt64(bitPattern: Int64(st.st_dev))
            self.inode = UInt64(st.st_ino)
        }
    }

    private let databasePath: String
    private let debounce: DispatchTimeInterval
    private let fallbackInterval: DispatchTimeInterval
    private let onNewRows: @Sendable (Int64) -> Void
    private let queue = DispatchQueue(label: "imessage-max.watcher")

    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var identities: [String: FileIdentity?] = [:]
    private var debounceTimer: DispatchSourceTimer?
    private var fallbackTimer: DispatchSourceTimer?
    private var lastMax: Int64 = 0
    private var running = false

    private var watchedPaths: [String] {
        let parent = (databasePath as NSString).deletingLastPathComponent
        return [databasePath, databasePath + "-wal", databasePath + "-shm", parent]
    }

    init(
        databasePath: String,
        debounce: DispatchTimeInterval = .milliseconds(250),
        fallbackInterval: DispatchTimeInterval = .seconds(5),
        onNewRows: @escaping @Sendable (Int64) -> Void
    ) {
        self.databasePath = databasePath
        self.debounce = debounce
        self.fallbackInterval = fallbackInterval
        self.onNewRows = onNewRows
    }

    func start() throws {
        let seed = try currentMaxRowid()
        queue.sync {
            guard !running else { return }
            lastMax = seed
            running = true
            refreshFileSources()
            armFallbackTimer()
            LiveInboxState.set(running: true)
        }
    }

    func stop() {
        queue.sync {
            stopLocked()
        }
    }

    var isRunning: Bool {
        queue.sync { running }
    }

    func watchedIdentitiesForTesting() -> [String: FileIdentity?] {
        queue.sync { identities }
    }

    func pollNowForTesting() {
        queue.sync { poll() }
    }

    private func stopLocked() {
        debounceTimer?.cancel()
        debounceTimer = nil
        fallbackTimer?.cancel()
        fallbackTimer = nil
        for source in sources.values {
            source.cancel()
        }
        sources.removeAll()
        identities.removeAll()
        running = false
        LiveInboxState.set(running: false)
    }

    private func refreshFileSources() {
        for filePath in watchedPaths {
            let identity = FileIdentity(path: filePath)
            if identities[filePath] != nil, identities[filePath]! == identity { continue }
            sources[filePath]?.cancel()
            sources[filePath] = identity.flatMap { _ in makeSource(path: filePath) }
            identities[filePath] = identity
        }
    }

    private func makeSource(path: String) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.refreshFileSources()
            self?.schedulePoll()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func schedulePoll() {
        guard running else { return }
        if debounceTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            debounceTimer = timer
        }
        debounceTimer?.schedule(deadline: .now() + debounce, repeating: .never)
    }

    private func armFallbackTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.refreshFileSources()
            self?.poll()
        }
        timer.schedule(deadline: .now() + fallbackInterval, repeating: fallbackInterval)
        timer.resume()
        fallbackTimer = timer
    }

    private func poll() {
        guard running else { return }
        let maxRowid: Int64
        do {
            maxRowid = try currentMaxRowid()
        } catch {
            Log.warning("MessageWatcher poll failed: \(error)")
            return
        }
        guard maxRowid > lastMax else { return }
        lastMax = maxRowid
        onNewRows(maxRowid)
    }

    private func currentMaxRowid() throws -> Int64 {
        let db = Database(path: databasePath)
        return try db.query("SELECT COALESCE(MAX(ROWID), 0) FROM message") { $0.int(0) }.first ?? 0
    }
}
