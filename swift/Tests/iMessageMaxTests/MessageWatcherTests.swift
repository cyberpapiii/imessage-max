import Synchronization
import XCTest
@testable import iMessageMax

final class MessageWatcherTests: XCTestCase {
    private func waitUntil(
        _ timeout: Duration = .seconds(3),
        _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await AsyncTimeout.sleep(.milliseconds(50))
        }
        return condition()
    }

    private func makeWalFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "watcher")
        try fixture.execute("PRAGMA journal_mode=WAL;")
        try fixture.insertHandle(rowId: 1, handle: "+15550001111")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550001111")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        return fixture
    }

    func testFiresWhenARowIsInserted() async throws {
        let fixture = try makeWalFixture()
        let collected = Mutex<[Int64]>([])
        let watcher = MessageWatcher(
            databasePath: fixture.path,
            debounce: .milliseconds(50),
            fallbackInterval: .milliseconds(400)
        ) { rowid in
            collected.withLock { $0.append(rowid) }
        }
        watcher.start()
        defer { watcher.stop() }

        try fixture.insertMessage(rowId: 5, guid: "w-5", text: "hi", date: 1, isFromMe: false, handleId: 1)
        let fired = await waitUntil { collected.withLock { $0.last } == 5 }
        XCTAssertTrue(fired, "watcher did not observe ROWID 5")
    }

    func testDebouncesABurstIntoOnePoll() async throws {
        let fixture = try makeWalFixture()
        let collected = Mutex<[Int64]>([])
        let watcher = MessageWatcher(
            databasePath: fixture.path,
            debounce: .milliseconds(80),
            fallbackInterval: .seconds(30)
        ) { rowid in
            collected.withLock { $0.append(rowid) }
        }
        watcher.start()
        defer { watcher.stop() }

        var batch = ""
        for rowid in 1...20 {
            batch += """
                INSERT INTO message (ROWID, guid, text, date, is_from_me, handle_id, associated_message_type)
                VALUES (\(rowid), 'w-\(rowid)', 'm\(rowid)', 1, 0, 1, 0);
                """
        }
        try fixture.execute(batch)
        _ = await waitUntil { !collected.withLock { $0.isEmpty } }
        await AsyncTimeout.sleep(.milliseconds(200))
        let values = collected.withLock { $0 }
        XCTAssertLessThanOrEqual(values.count, 2, "burst produced \(values)")
        XCTAssertEqual(values.last, 20)
    }

    func testReregistersAfterWalRotation() async throws {
        let fixture = try makeWalFixture()
        let collected = Mutex<[Int64]>([])
        let watcher = MessageWatcher(
            databasePath: fixture.path,
            debounce: .milliseconds(50),
            fallbackInterval: .seconds(30)
        ) { rowid in
            collected.withLock { $0.append(rowid) }
        }
        watcher.start()
        defer { watcher.stop() }

        let walPath = fixture.path + "-wal"
        let walInode = { (try? FileManager.default.attributesOfItem(atPath: walPath)[.systemFileNumber]) as? Int }
        try fixture.insertMessage(rowId: 6, guid: "w-6", text: "before", date: 1, isFromMe: false, handleId: 1)
        let before = try XCTUnwrap(walInode())
        let seeded = await waitUntil { collected.withLock { $0.contains(6) } }
        XCTAssertTrue(seeded, "watcher did not observe ROWID 6")
        // Leaving WAL mode needs the watcher's reads out of the way.
        try fixture.execute("PRAGMA busy_timeout=2000;")

        // Leaving WAL mode checkpoints and deletes -wal; the next write in WAL
        // mode creates a new one. Messages.app rotates it the same way when
        // its last connection closes. (Renaming -wal under an open
        // connection is a disk I/O error in SQLite, which made this skip.)
        try fixture.execute("PRAGMA journal_mode=DELETE;")
        XCTAssertNil(walInode(), "-wal should be gone outside WAL mode")
        try fixture.execute("PRAGMA journal_mode=WAL;")
        try fixture.insertMessage(rowId: 7, guid: "w-7", text: "after", date: 2, isFromMe: false, handleId: 1)
        XCTAssertNotEqual(try XCTUnwrap(walInode()), before, "-wal should be a new file")

        // The fallback poll is 30 s out, so only file events can report these.
        let reported = await waitUntil { collected.withLock { $0.contains(7) } }
        XCTAssertTrue(reported, "insert after rotation was not reported")

        // The new -wal already exists, so this write raises no directory
        // event: only a source registered on the new file sees it.
        try fixture.insertMessage(rowId: 8, guid: "w-8", text: "later", date: 3, isFromMe: false, handleId: 1)
        let followed = await waitUntil { collected.withLock { $0.contains(8) } }
        XCTAssertTrue(followed, "watcher did not follow the rotated -wal")
    }

    /// chat.db unreadable at startup must not switch live notifications off
    /// for the life of the process: the watcher keeps trying until it can
    /// read the database.
    func testStartsWatchingOnceTheDatabaseBecomesReadable() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-late-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("chat.db").path

        let collected = Mutex<[Int64]>([])
        let watcher = MessageWatcher(
            databasePath: path,
            debounce: .milliseconds(50),
            fallbackInterval: .seconds(30)
        ) { rowid in
            collected.withLock { $0.append(rowid) }
        }
        watcher.start()
        defer { watcher.stop() }
        XCTAssertTrue(watcher.isRunning)
        XCTAssertFalse(watcher.isLive, "not live until chat.db has been read")

        let fixture = try makeWalFixture()
        try fixture.insertMessage(rowId: 3, guid: "late-3", text: "old", date: 1, isFromMe: false, handleId: 1)
        // A WAL database copied without its -shm cannot be opened read-only.
        try fixture.execute("PRAGMA journal_mode=DELETE;")
        try FileManager.default.copyItem(atPath: fixture.path, toPath: path)
        watcher.pollNow()
        XCTAssertEqual(collected.withLock { $0 }, [], "the first read only seeds")
        XCTAssertTrue(watcher.isLive)

        let late = try ToolTestDatabase(attachingTo: path)
        try late.insertMessage(rowId: 4, guid: "late-4", text: "new", date: 2, isFromMe: false, handleId: 1)
        watcher.pollNow()
        XCTAssertEqual(collected.withLock { $0 }, [4])
    }

    /// A replaced chat.db (restore, reset, re-sync) restarts ROWIDs low. The
    /// watcher resets its maximum rather than staying silent until new rows
    /// pass the old one.
    func testResetsWhenTheDatabaseIsReplaced() async throws {
        let fixture = try makeWalFixture()
        try fixture.insertMessage(rowId: 20, guid: "old-20", text: "old", date: 1, isFromMe: false, handleId: 1)
        let collected = Mutex<[Int64]>([])
        let watcher = MessageWatcher(
            databasePath: fixture.path,
            debounce: .milliseconds(50),
            fallbackInterval: .seconds(30)
        ) { rowid in
            collected.withLock { $0.append(rowid) }
        }
        watcher.start()
        defer { watcher.stop() }

        let replacement = try ToolTestDatabase(name: "watcher-replacement")
        try replacement.insertMessage(rowId: 2, guid: "new-2", text: "restored", date: 1, isFromMe: false, handleId: 1)
        try fixture.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: fixture.path + suffix)
        }
        _ = try FileManager.default.replaceItemAt(fixture.url, withItemAt: replacement.url)
        watcher.pollNow()
        XCTAssertEqual(collected.withLock { $0 }, [], "a smaller maximum is a reset, not new mail")

        let reopened = try ToolTestDatabase(attachingTo: fixture.path)
        try reopened.insertMessage(rowId: 3, guid: "new-3", text: "after", date: 2, isFromMe: false, handleId: 1)
        watcher.pollNow()
        XCTAssertEqual(collected.withLock { $0 }, [3])
    }

    func testStopIsIdempotentAndLeavesNoTimers() async throws {
        let fixture = try makeWalFixture()
        let collected = Mutex<[Int64]>([])
        let watcher = MessageWatcher(
            databasePath: fixture.path,
            debounce: .milliseconds(50),
            fallbackInterval: .milliseconds(200)
        ) { rowid in
            collected.withLock { $0.append(rowid) }
        }
        watcher.start()
        watcher.stop()
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
        XCTAssertFalse(watcher.isLive)

        try fixture.insertMessage(rowId: 9, guid: "w-9", text: "late", date: 3, isFromMe: false, handleId: 1)
        let fired = await waitUntil(.seconds(1)) { !collected.withLock { $0.isEmpty } }
        XCTAssertFalse(fired, "stopped watcher still fired: \(collected.withLock { $0 })")
    }
}
