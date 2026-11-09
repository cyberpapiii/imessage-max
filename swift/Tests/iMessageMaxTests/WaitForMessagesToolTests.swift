import Darwin
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MCP
import Synchronization
import XCTest
@testable import iMessageMax

/// Polls `condition` on a Dispatch timer until it holds or `timeout` passes.
func eventually(_ timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        await AsyncTimeout.sleep(.milliseconds(20))
    }
    return condition()
}

private func resultText(_ handler: ToolHandler, _ args: [String: Value]) async throws -> String {
    try decodeJSONString(from: try await handler(args))
}

final class MessageArrivalsTests: XCTestCase {
    func testARowAboveTheCursorWakesOnlyTheWaitersBelowIt() async {
        let arrivals = MessageArrivals()
        async let low = arrivals.wait(above: 10, timeout: .seconds(5))
        async let high = arrivals.wait(above: 20, timeout: .milliseconds(500))
        let bothWaiting = await eventually { arrivals.waiting == 2 }
        XCTAssertTrue(bothWaiting)
        arrivals.rowsArrived(maxRowid: 15)
        let (lowWake, highWake) = await (low, high)
        XCTAssertEqual(lowWake, .arrived)
        XCTAssertEqual(highWake, .deadline)
    }

    func testARowReportedBeforeTheWaitStartsEndsItAtOnce() async {
        let arrivals = MessageArrivals()
        arrivals.rowsArrived(maxRowid: 11)
        let wake = await arrivals.wait(above: 10, timeout: .seconds(5))
        XCTAssertEqual(wake, .arrived)
    }

    func testDrainEndsWaitsNowAndLater() async {
        let arrivals = MessageArrivals()
        async let blocked = arrivals.wait(above: 1, timeout: .seconds(30))
        let waiting = await eventually { arrivals.waiting == 1 }
        XCTAssertTrue(waiting)
        arrivals.drain()
        let first = await blocked
        XCTAssertEqual(first, .draining)
        let later = await arrivals.wait(above: 1, timeout: .seconds(30))
        XCTAssertEqual(later, .draining)
        arrivals.updatePending(false)
        let afterUpdateCleared = await arrivals.wait(above: 1, timeout: .seconds(30))
        XCTAssertEqual(afterUpdateCleared, .draining, "a stop must stay a stop")
    }

    func testAPendingUpdateEndsWaitsUntilItIsWithdrawn() async {
        let arrivals = MessageArrivals()
        async let blocked = arrivals.wait(above: 1, timeout: .seconds(30))
        let waiting = await eventually { arrivals.waiting == 1 }
        XCTAssertTrue(waiting)
        arrivals.updatePending(true)
        let first = await blocked
        XCTAssertEqual(first, .draining)
        let during = await arrivals.wait(above: 1, timeout: .seconds(30))
        XCTAssertEqual(during, .draining)
        arrivals.updatePending(false)
        let after = await arrivals.wait(above: 1, timeout: .milliseconds(100))
        XCTAssertEqual(after, .deadline)
    }

    func testCancellingTheTaskEndsTheWaitPromptly() async {
        let arrivals = MessageArrivals()
        let task = Task { await arrivals.wait(above: 1, timeout: .seconds(30)) }
        let waiting = await eventually { arrivals.waiting == 1 }
        XCTAssertTrue(waiting)
        let start = ContinuousClock.now
        task.cancel()
        let wake = await task.value
        XCTAssertEqual(wake, .cancelled)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        XCTAssertEqual(arrivals.waiting, 0)
    }

    func testATaskCancelledBeforeItWaitsNeverBlocks() async {
        let arrivals = MessageArrivals()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await arrivals.wait(above: 1, timeout: .seconds(30))
        }
        let wake = await task.value
        XCTAssertEqual(wake, .cancelled)
        XCTAssertEqual(arrivals.waiting, 0)
    }

    func testWaitsPastCapacityAreRefused() async {
        let arrivals = MessageArrivals(capacity: 1)
        async let first = arrivals.wait(above: 1, timeout: .seconds(5))
        let waiting = await eventually { arrivals.waiting == 1 }
        XCTAssertTrue(waiting)
        let second = await arrivals.wait(above: 1, timeout: .seconds(5))
        XCTAssertEqual(second, .full)
        arrivals.rowsArrived(maxRowid: 2)
        let firstWake = await first
        XCTAssertEqual(firstWake, .arrived)
    }
}

final class WaitForMessagesToolTests: XCTestCase {
    private let now = AppleTime.fromDate(Date())

    private func date(_ rowid: Int) -> Int64 {
        now - Int64(200 - rowid) * 1_000_000_000
    }

    /// Alice's DM (chat 1) holds her row 100 and my reply 101. Bob and Alice
    /// share the group, chat 2.
    private func makeFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "wait-for-messages")
        try fixture.execute("PRAGMA journal_mode=WAL;")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001", style: 45)
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        try fixture.insertChat(rowId: 2, guid: "iMessage;+;chat-group", displayName: "Weekend", style: 43)
        try fixture.joinChatHandle(chatId: 2, handleId: 1)
        try fixture.joinChatHandle(chatId: 2, handleId: 2)
        try say(fixture, 100, "are you around?", chat: 1, from: 1)
        try say(fixture, 101, "yes", chat: 1, from: nil, handle: 1)
        return fixture
    }

    /// `from` nil is me. A message I send in a DM still carries the other
    /// person's handle, as chat.db stores it.
    private func say(
        _ fixture: ToolTestDatabase, _ rowid: Int, _ text: String, chat: Int, from sender: Int?, handle: Int? = nil,
        date: Int64? = nil
    ) throws {
        try fixture.execute("BEGIN;")
        try fixture.insertMessage(
            rowId: rowid, guid: "w-\(rowid)", text: text, date: date ?? self.date(rowid), isFromMe: sender == nil,
            handleId: sender ?? handle)
        try fixture.joinChatMessage(chatId: chat, messageId: rowid)
        try fixture.execute("COMMIT;")
    }

    private func tool(_ fixture: ToolTestDatabase, _ arrivals: MessageArrivals) -> ToolHandler {
        WaitForMessagesTool.definition(db: fixture.database(), resolver: makeSeededResolver(), arrivals: arrivals).handler
    }

    private func call(_ handler: ToolHandler, _ args: [String: Value]) async throws -> [String: Any] {
        try decodeJSONDictionary(from: try await handler(args))
    }


    func testAMatchingMessageAlreadyPastTheCursorReturnsAtOnceWithoutMyOwn() async throws {
        let fixture = try makeFixture()
        let json = try await call(tool(fixture, MessageArrivals()), ["since_rowid": .int(99), "timeout": .int(30)])
        XCTAssertEqual(json["status"] as? String, "messages")
        XCTAssertEqual(try itemIds(json, "messages"), ["msg_100"])
        XCTAssertEqual(json["since_rowid"] as? Int, 99)
        XCTAssertEqual(json["next_rowid"] as? Int, 101)
    }

    func testIncludeFromMeCountsMyMessages() async throws {
        let fixture = try makeFixture()
        let json = try await call(
            tool(fixture, MessageArrivals()), ["since_rowid": .int(100), "include_from_me": .bool(true)])
        XCTAssertEqual(try itemIds(json, "messages"), ["msg_101"])
    }

    /// The whole path: a row lands in chat.db, MessageWatcher sees it, and
    /// the blocked call returns it.
    func testAMessageThatArrivesWhileWaitingEndsTheWait() async throws {
        let fixture = try makeFixture()
        let arrivals = MessageArrivals()
        let watcher = MessageWatcher(databasePath: fixture.path, debounce: .milliseconds(50)) {
            arrivals.rowsArrived(maxRowid: $0.maxRowid)
        }
        watcher.start()
        defer { watcher.stop() }
        let handler = tool(fixture, arrivals)
        let start = ContinuousClock.now
        let call = Task { try await resultText(handler, ["since_rowid": .int(101), "timeout": .int(20)]) }
        let waiting = await eventually { arrivals.waiting == 1 }
        XCTAssertTrue(waiting)
        try say(fixture, 102, "on my way", chat: 2, from: 2)

        let text = try await call.value
        print("wait_for_messages example: \(text)")
        let json = try decodeJSONDictionary(from: text)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        XCTAssertEqual(json["status"] as? String, "messages")
        XCTAssertEqual(try itemIds(json, "messages"), ["msg_102"])
        XCTAssertEqual(json["since_rowid"] as? Int, 101)
        XCTAssertEqual(json["next_rowid"] as? Int, 102)
        let message = try XCTUnwrap(try decodeJSONArray(json["messages"]).first)
        XCTAssertEqual(message["from"] as? String, "Bob Brown")
        XCTAssertEqual(message["text"] as? String, "on my way")
    }

    func testFromPersonWaitsPastOtherPeopleAndMyOwnMessagesToThem() async throws {
        let fixture = try makeFixture()
        let arrivals = MessageArrivals()
        let handler = tool(fixture, arrivals)
        let call = Task {
            try await resultText(handler, ["since_rowid": .int(101), "from_person": .string("Alice"), "timeout": .int(20)])
        }
        let waiting = await eventually { arrivals.waiting == 1 }
        XCTAssertTrue(waiting)
        try say(fixture, 102, "still there?", chat: 1, from: nil, handle: 1)
        try say(fixture, 103, "me too", chat: 2, from: 2)
        arrivals.rowsArrived(maxRowid: 103)
        let waitingAgain = await eventually { arrivals.waiting == 1 }
        XCTAssertTrue(waitingAgain, "a row from someone else ended the wait")
        try say(fixture, 104, "sorry, here", chat: 1, from: 1)
        arrivals.rowsArrived(maxRowid: 104)

        let json = try decodeJSONDictionary(from: try await call.value)
        XCTAssertEqual(json["status"] as? String, "messages")
        XCTAssertEqual(try itemIds(json, "messages"), ["msg_104"])
        XCTAssertEqual(json["next_rowid"] as? Int, 104)
    }

    /// A timeout still moves the cursor past rows the filters skipped, and
    /// get_messages_since from the old cursor still sees them.
    func testATimeoutAdvancesTheCursorPastRowsThatDidNotMatch() async throws {
        let fixture = try makeFixture()
        try say(fixture, 102, "me too", chat: 2, from: 2)
        let start = ContinuousClock.now
        let json = try await call(
            tool(fixture, MessageArrivals()),
            ["since_rowid": .int(101), "from_person": .string("Alice"), "timeout": .int(1)])
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(900))
        XCTAssertEqual(json["status"] as? String, "timeout")
        XCTAssertEqual(try itemIds(json, "messages"), [])
        XCTAssertEqual(json["next_rowid"] as? Int, 102)

        let since = try await callTool("get_messages_since", ["since_rowid": .int(101)], database: fixture.database())
        XCTAssertEqual(try itemIds(since, "messages"), ["msg_102"])
    }

    func testLateSyncedHistoryIsNotNew() async throws {
        let fixture = try makeFixture()
        try say(fixture, 102, "from last year", chat: 1, from: 1, date: date(101) - 2 * 3_600 * 1_000_000_000)
        let json = try await call(tool(fixture, MessageArrivals()), ["since_rowid": .int(101), "timeout": .int(1)])
        XCTAssertEqual(json["status"] as? String, "timeout")
        XCTAssertEqual(try itemIds(json, "messages"), [])
        XCTAssertEqual(json["next_rowid"] as? Int, 102)
    }

    func testWithoutACursorOnlyMessagesAfterTheCallCount() async throws {
        let fixture = try makeFixture()
        let json = try await call(tool(fixture, MessageArrivals()), ["timeout": .int(1)])
        XCTAssertEqual(json["status"] as? String, "timeout")
        XCTAssertEqual(json["since_rowid"] as? Int, 101)
        XCTAssertEqual(json["next_rowid"] as? Int, 101)
    }

    func testADrainEndsTheWaitWithStoppingAndTheCursor() async throws {
        let fixture = try makeFixture()
        let arrivals = MessageArrivals()
        let handler = tool(fixture, arrivals)
        let call = Task { try await resultText(handler, ["since_rowid": .int(101), "timeout": .int(50)]) }
        let waiting = await eventually { arrivals.waiting == 1 }
        XCTAssertTrue(waiting)
        let start = ContinuousClock.now
        arrivals.drain()
        let json = try decodeJSONDictionary(from: try await call.value)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        XCTAssertEqual(json["status"] as? String, "stopping")
        XCTAssertEqual(json["next_rowid"] as? Int, 101)
    }

    func testCancellingTheCallEndsTheWait() async throws {
        let fixture = try makeFixture()
        let arrivals = MessageArrivals()
        let handler = tool(fixture, arrivals)
        let call = Task { try await handler(["since_rowid": .int(101), "timeout": .int(50)]) }
        let waiting = await eventually { arrivals.waiting == 1 }
        XCTAssertTrue(waiting)
        let start = ContinuousClock.now
        call.cancel()
        do {
            _ = try await call.value
            XCTFail("a cancelled wait returned a result")
        } catch is CancellationError {}
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        XCTAssertEqual(arrivals.waiting, 0)
    }

    func testAWaitPastCapacityIsRefused() async throws {
        let fixture = try makeFixture()
        let arrivals = MessageArrivals(capacity: 1)
        let handler = tool(fixture, arrivals)
        let first = Task { try await resultText(handler, ["since_rowid": .int(101), "timeout": .int(20)]) }
        let waiting = await eventually { arrivals.waiting == 1 }
        XCTAssertTrue(waiting)
        do {
            _ = try await handler(["since_rowid": .int(101)])
            XCTFail("a wait past capacity was accepted")
        } catch let failure as ToolFailure {
            XCTAssertEqual(failure.code, "too_many_waits")
        }
        first.cancel()
        _ = try? await first.value
    }
}

/// The wait on the lanes clients use: plug's legacy HTTP, and a stop.
final class WaitForMessagesLaneTests: XCTestCase {
    private func fixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "wait-lanes")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        try fixture.insertMessage(rowId: 100, guid: "l-100", text: "hi", date: AppleTime.fromDate(Date()), isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 100)
        return fixture
    }

    private func catalog(_ fixture: ToolTestDatabase, _ arrivals: MessageArrivals) -> ToolCatalog {
        ToolCatalog([WaitForMessagesTool.definition(db: fixture.database(), resolver: makeSeededResolver(), arrivals: arrivals)])
    }

    func testNotificationsCancelledEndsALegacyHTTPWait() async throws {
        let fixture = try fixture()
        let arrivals = MessageArrivals()
        let app = await makeTestTransport(catalog: catalog(fixture, arrivals)).application()
        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession()
            async let call = client.post(
                #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"wait_for_messages","arguments":{"since_rowid":100,"timeout":50}}}"#,
                headers: jsonHeaders(sessionId: sessionId)
            )
            let waiting = await eventually { arrivals.waiting == 1 }
            XCTAssertTrue(waiting)
            let start = ContinuousClock.now
            let cancel = try await client.post(
                #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#,
                headers: jsonHeaders(sessionId: sessionId)
            )
            XCTAssertEqual(cancel.head.status, .accepted)
            let response = try await call
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
            let result = try XCTUnwrap(try decodeJSON(from: response.body)["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true)
            XCTAssertEqual(arrivals.waiting, 0)
        }
    }

    /// beginStop is the drain SIGUSR1 and an installed update start, and the
    /// one SIGTERM starts through the service group.
    func testAStopEndsAnHTTPWaitWithStoppingBeforeTheDrainBound() async throws {
        let fixture = try fixture()
        let arrivals = MessageArrivals()
        let port = try freeLoopbackPort()
        let transport = HTTPTransport(
            host: "127.0.0.1", port: port, accessToken: testAccessToken, catalog: catalog(fixture, arrivals),
            setupPermissions: makeTestSetupPermissions(), configuration: .test, onDrain: { arrivals.drain() })
        try await transport.connect(gracefulShutdownSignals: [])
        let session = try initializeSession(port: port)
        let body = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wait_for_messages","arguments":{"since_rowid":100,"timeout":50}}}"#
        let fd = try connectLoopback(port: port)
        defer { close(fd) }
        setRecvTimeout(fd, seconds: 10)
        try writeAll(fd, """
            POST / HTTP/1.1\r\n\
            Host: 127.0.0.1\r\n\
            Authorization: \(testAuthorization)\r\n\
            Content-Type: application/json\r\n\
            Accept: application/json, text/event-stream\r\n\
            Mcp-Session-Id: \(session)\r\n\
            Connection: close\r\n\
            Content-Length: \(body.utf8.count)\r\n\
            \r\n\
            \(body)
            """)
        let waiting = await eventually { arrivals.waiting == 1 }
        XCTAssertTrue(waiting)

        let start = ContinuousClock.now
        await transport.beginStop()
        let response = try readToEnd(fd)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3), "the wait held the drain open")
        let json = try XCTUnwrap(response.range(of: "\r\n\r\n").map { String(response[$0.upperBound...]) })
        let result = try XCTUnwrap(try decodeJSONDictionary(from: json)["result"] as? [String: Any], json)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any], "\(result)")
        XCTAssertEqual(structured["status"] as? String, "stopping")
        XCTAssertEqual(structured["next_rowid"] as? Int, 100)
        try await transport.waitForTermination()
    }

    private func readToEnd(_ fd: Int32) throws -> String {
        var received = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n == 0 { break }
            if n < 0 { throw SocketError(errno) }
            received.append(contentsOf: buffer.prefix(n))
        }
        return String(decoding: received, as: UTF8.self)
    }
}
