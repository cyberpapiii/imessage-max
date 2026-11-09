import Darwin
import Foundation

final class MessageWatcher: @unchecked Sendable {
    /// New rows above the last poll's MAX(ROWID).
    struct NewRows: Equatable, Sendable {
        let maxRowid: Int64
        /// Every new row is late-synced history (see LateHistory), so a
        /// client can skip this notification.
        var late = false
    }

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
    private let onNewRows: @Sendable (NewRows) -> Void
    private let queue = DispatchQueue(label: "imessage-max.watcher")

    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var identities: [String: FileIdentity?] = [:]
    private var debounceTimer: DispatchSourceTimer?
    private var fallbackTimer: DispatchSourceTimer?
    private var lastMax: Int64?
    private var pollFailing = false
    private var running = false

    private var watchedPaths: [String] {
        let parent = (databasePath as NSString).deletingLastPathComponent
        return [databasePath, databasePath + "-wal", databasePath + "-shm", parent]
    }

    init(
        databasePath: String,
        debounce: DispatchTimeInterval = .milliseconds(250),
        fallbackInterval: DispatchTimeInterval = .seconds(5),
        onNewRows: @escaping @Sendable (NewRows) -> Void
    ) {
        self.databasePath = databasePath
        self.debounce = debounce
        self.fallbackInterval = fallbackInterval
        self.onNewRows = onNewRows
    }

    func start() {
        queue.sync {
            guard !running else { return }
            running = true
            refreshFileSources()
            armFallbackTimer()
            poll()
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

    var isLive: Bool {
        queue.sync { running && lastMax != nil }
    }

    func pollNow() {
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
        lastMax = nil
        pollFailing = false
        running = false
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
            if !pollFailing {
                pollFailing = true
                Log.warning("MessageWatcher cannot read chat.db, will keep retrying: \(error)")
            }
            return
        }
        if pollFailing {
            pollFailing = false
            Log.info("MessageWatcher reading chat.db again")
        }
        guard let previous = lastMax else {
            lastMax = maxRowid
            return
        }
        guard maxRowid != previous else { return }
        lastMax = maxRowid
        if maxRowid > previous {
            onNewRows(NewRows(maxRowid: maxRowid, late: allLate(after: previous, through: maxRowid)))
        }
    }

    /// Whether every row in (previous, maxRowid] is late against the rows at
    /// or below `previous`. On a read error the rows count as new.
    private func allLate(after previous: Int64, through maxRowid: Int64) -> Bool {
        let db = Database(path: databasePath)
        do {
            let baseline = try LateHistory.baseline(db: db, atOrBelow: previous)
            let newest = try db.query(
                "SELECT MAX(date) FROM message WHERE ROWID > ? AND ROWID <= ?", params: [previous, maxRowid]
            ) { $0.optionalInt(0) }.first ?? nil
            return LateHistory.isLate(newest, highWater: baseline)
        } catch {
            return false
        }
    }

    private func currentMaxRowid() throws -> Int64 {
        let db = Database(path: databasePath)
        return try db.query("SELECT COALESCE(MAX(ROWID), 0) FROM message") { $0.int(0) }.first ?? 0
    }
}
