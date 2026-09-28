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
        let before = watcher.watchedIdentitiesForTesting()[walPath]

        try fixture.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        let aside = fixture.path + "-wal.aside"
        do {
            if FileManager.default.fileExists(atPath: walPath) {
                try FileManager.default.moveItem(atPath: walPath, toPath: aside)
            }
            try fixture.insertMessage(rowId: 7, guid: "w-7", text: "after", date: 2, isFromMe: false, handleId: 1)
        } catch {
            throw XCTSkip("SQLite refused the -wal rename or follow-up insert: \(error)")
        }
        defer { try? FileManager.default.removeItem(atPath: aside) }

        watcher.pollNowForTesting()
        let after = watcher.watchedIdentitiesForTesting()[walPath]
        if before != nil {
            XCTAssertNotEqual(before, after, "expected -wal identity to change after rotation")
        }
        XCTAssertTrue(collected.withLock { $0.contains(7) }, "insert after rotation was not reported")
    }

    /// chat.db unreadable at startup must not switch live notifications off
    /// for the life of the process. At f005283 start() threw, the caller
    /// logged it, and nothing ever tried again.
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
        XCTAssertFalse(LiveInboxState.isRunning, "not live until chat.db has been read")

        let fixture = try makeWalFixture()
        try fixture.insertMessage(rowId: 3, guid: "late-3", text: "old", date: 1, isFromMe: false, handleId: 1)
        // A WAL database copied without its -shm cannot be opened read-only.
        try fixture.execute("PRAGMA journal_mode=DELETE;")
        try FileManager.default.copyItem(atPath: fixture.path, toPath: path)
        watcher.pollNowForTesting()
        XCTAssertEqual(collected.withLock { $0 }, [], "the first read only seeds")
        XCTAssertTrue(LiveInboxState.isRunning)

        let late = try ToolTestDatabase(attachingTo: path)
        try late.insertMessage(rowId: 4, guid: "late-4", text: "new", date: 2, isFromMe: false, handleId: 1)
        watcher.pollNowForTesting()
        XCTAssertEqual(collected.withLock { $0 }, [4])
    }

    /// A replaced chat.db (restore, reset, re-sync) restarts ROWIDs low.
    /// At f005283 the watcher kept the old maximum and stayed silent until
    /// new rows passed it.
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
        watcher.pollNowForTesting()
        XCTAssertEqual(collected.withLock { $0 }, [], "a smaller maximum is a reset, not new mail")

        let reopened = try ToolTestDatabase(attachingTo: fixture.path)
        try reopened.insertMessage(rowId: 3, guid: "new-3", text: "after", date: 2, isFromMe: false, handleId: 1)
        watcher.pollNowForTesting()
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

        try fixture.insertMessage(rowId: 9, guid: "w-9", text: "late", date: 3, isFromMe: false, handleId: 1)
        let fired = await waitUntil(.seconds(1)) { !collected.withLock { $0.isEmpty } }
        XCTAssertFalse(fired, "stopped watcher still fired: \(collected.withLock { $0 })")
    }
}
