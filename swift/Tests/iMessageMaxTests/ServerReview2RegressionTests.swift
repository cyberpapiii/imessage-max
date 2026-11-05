import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import IMessageMaxContract
import Logging
import MCP
import NIOCore
import XCTest
@testable import iMessageMax

/// Regression tests for the second server/send/contacts review. Self-contained:
/// every helper lives in this file.
final class ServerReview2RegressionTests: XCTestCase {

    // MARK: - Send stops on cancellation

    /// A send cancelled after its first payload went out dispatches nothing
    /// further and reports partial_failure, not a success.
    func testCancelledSendDispatchesNothingFurther() async throws {
        let fixture = try makeSendFixture()
        let runner = CancellingRunner()
        let tool = SendTool(
            db: fixture.database(), resolver: makeSeededResolver(), runner: runner,
            verifier: SendVerifier(db: fixture.database(), maxAttempts: 1, pollInterval: .milliseconds(0))
        )

        let call = Task {
            try await tool.execute(args: [
                "to": .string("+15550000001"),
                "text": .string("Hello"),
                "file_paths": .array([.string("/tmp/a.jpg"), .string("/tmp/b.jpg")]),
            ])
        }
        do {
            _ = try await call.value
            XCTFail("a cancelled multi-payload send must not report success")
        } catch let failure as ToolFailure {
            let json = try decodeJSONDictionary(from: failure.content)
            XCTAssertEqual(json["status"] as? String, "partial_failure")
            XCTAssertEqual(json["disposition"] as? String, "not_started")
            XCTAssertEqual(json["retry_safe"] as? Bool, false)
            let message = json["message"] as? String ?? ""
            XCTAssertTrue(message.contains("file 'a.jpg'"), message)
            XCTAssertTrue((json["error"] as? String ?? "").contains("cancelled"), "\(json)")
        }
        XCTAssertEqual(runner.calls, 1, "nothing may be dispatched after cancellation")
    }

    /// Cancelled before the first payload: nothing is sent, and the answer
    /// says so (failed, not_started).
    func testSendCancelledBeforeDispatchSendsNothing() async throws {
        let fixture = try makeSendFixture()
        let runner = CancellingRunner()
        let tool = SendTool(
            db: fixture.database(), resolver: makeSeededResolver(), runner: runner,
            verifier: SendVerifier(db: fixture.database(), maxAttempts: 1, pollInterval: .milliseconds(0))
        )
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await tool.execute(args: ["to": .string("+15550000001"), "text": .string("Hello")])
        }
        do {
            _ = try await call.value
            XCTFail("a cancelled send must not report success")
        } catch let failure as ToolFailure {
            let json = try decodeJSONDictionary(from: failure.content)
            XCTAssertEqual(json["status"] as? String, "failed")
            XCTAssertEqual(json["disposition"] as? String, "not_started")
        }
        XCTAssertEqual(runner.calls, 0)
    }

    // MARK: - Modern stdio cancellation

    /// A `notifications/cancelled` stops a modern stdio `tools/call`, whether
    /// the notification is legacy-shaped or carries the modern `_meta`.
    func testCancelledNotificationStopsModernStdioToolCall() async throws {
        let cancels = [
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5,"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#,
        ]
        for cancel in cancels {
            let (started, startedSink) = AsyncStream<Void>.makeStream()
            let catalog = ToolCatalog([waitForCancelTool(started: startedSink)])
            let base = FeedableBaseTransport()
            let dual = DualEraStdio(base: base, catalog: catalog)
            try await dual.start()
            let clock = ContinuousClock()
            let begin = clock.now

            await base.feed(
                #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"wait_for_cancel","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
            )
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
            await base.feed(cancel)

            let sent = await base.firstSent()
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
            XCTAssertLessThan(clock.now - begin, .seconds(5), "the call ran on after \(cancel)")
            XCTAssertEqual(reply["id"] as? Int, 5)
            XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true, "\(reply)")
            await dual.stop()
        }
    }

    // MARK: - HTTP client id errors

    /// A request reusing an in-flight id is the client's error: 400 with
    /// -32600 and its id, not a 500 with a null id.
    func testDuplicateInFlightIdIsA400CarryingTheId() async throws {
        let (started, startedSink) = AsyncStream<Void>.makeStream()
        var configuration = HTTPTransport.Configuration(requestTimeout: .seconds(5), cleanupInterval: .milliseconds(20))
        configuration.makeServer = { catalog in
            let server = await Version.makeServer(catalog: catalog)
            await server.withMethodHandler(Review2SlowMethod.self) { _ in
                startedSink.yield()
                await AsyncTimeout.sleep(.milliseconds(300))
                return .init()
            }
            return server
        }
        let transport = makeTransport(configuration: configuration)
        let app = await transport.application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await openSession(client)
            let slow = #"{"jsonrpc":"2.0","id":"dup","method":"tests/review2-slow","params":{}}"#
            async let first = client.executeRequest(uri: "/", method: .post, headers: headers(sessionId: sessionId), body: ByteBuffer(string: slow))
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()

            let second = try await client.executeRequest(uri: "/", method: .post, headers: headers(sessionId: sessionId), body: ByteBuffer(string: slow))
            XCTAssertEqual(second.head.status, .badRequest)
            let json = try object(second.body)
            XCTAssertEqual(json["id"] as? String, "dup")
            XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? Int, -32600)

            let firstStatus = try await first.head.status
            XCTAssertEqual(firstStatus, .ok)
        }
    }

    /// An id that is not a JSON scalar is an invalid request (400, -32600).
    func testNonScalarIdIsA400() async throws {
        let app = await makeTransport().application()
        try await app.test(TestingSetup.router) { client in
            let sessionId = try await openSession(client)
            let response = try await client.executeRequest(
                uri: "/", method: .post, headers: headers(sessionId: sessionId),
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":{"a":1},"method":"tools/list","params":{}}"#)
            )
            XCTAssertEqual(response.head.status, .badRequest)
            let json = try object(response.body)
            XCTAssertTrue(json["id"] is NSNull)
            XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? Int, -32600)
        }
    }

    // MARK: - Staging root

    /// A symlinked staging root is refused before anything follows the link,
    /// so the link's target keeps its permissions.
    func testSymlinkedStagingRootIsRefusedBeforeItIsChmodded() throws {
        let tmp = try XCTUnwrap(SecurePath.absoluteLexicalPath(FileManager.default.temporaryDirectory.path))
        let scratch = URL(fileURLWithPath: tmp, isDirectory: true)
            .appendingPathComponent("review2-\(UUID().uuidString)", isDirectory: true)
        let target = scratch.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
        let sourceFile = scratch.appendingPathComponent("payload.txt")
        try Data("payload".utf8).write(to: sourceFile)

        let stager = OutgoingFileStager(root: root)
        let source = try stager.openSource(sourceFile.path)
        defer { source.close() }
        XCTAssertThrowsError(try stager.stage(source)) { error in
            guard case SendError.invalidParams = error else { return XCTFail("\(error)") }
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755, "the link's target must not be re-permissioned")
    }

    // MARK: - SSE shutdown

    /// `closeAll` ends open streams and every stream registered after it, so
    /// a GET that registers during shutdown cannot hold the process open.
    func testCloseAllEndsOpenStreamsAndLaterOnes() async {
        let manager = SSEConnectionManager(keepAliveInterval: .seconds(60))
        let open = await manager.register(info: SSEConnectionInfo(sessionId: "a"))
        await manager.closeAll()
        let late = await manager.register(info: SSEConnectionInfo(sessionId: "b"))

        for channel in [open, late] {
            var received = 0
            for await _ in channel.stream { received += 1 }
            XCTAssertEqual(received, 0)
        }
        let count = await manager.connectionCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - "yesterday"

    /// "yesterday" is the start of yesterday, as "today" is the start of today.
    func testYesterdayIsTheStartOfYesterday() throws {
        let calendar = Calendar.current
        func startOfYesterday() -> Date {
            calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
        }
        let before = startOfYesterday()
        let parsed = try XCTUnwrap(AppleTime.toDate(AppleTime.parse("yesterday")))
        let after = startOfYesterday()
        XCTAssertTrue(parsed == before || parsed == after, "\(parsed) is not the start of yesterday")
    }
}

// MARK: - Helpers

/// Cancels the calling task on its first send, the way a client's
/// notifications/cancelled lands while the first payload is in flight.
private final class CancellingRunner: ScriptRunning, @unchecked Sendable {
    private(set) var calls = 0

    func send(_ payload: SendPayload, to target: SendTarget) async -> Result<Void, SendFailure> {
        calls += 1
        withUnsafeCurrentTask { $0?.cancel() }
        return .success(())
    }
}

private func makeSendFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "send-review2")
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertChat(rowId: 1, guid: "iMessage;-;review2-guid")
    try fixture.joinChatHandle(chatId: 1, handleId: 1)
    return fixture
}

private func waitForCancelTool(started: AsyncStream<Void>.Continuation) -> ToolDefinition {
    ToolDefinition(name: "wait_for_cancel", description: "", inputSchema: InputSchema.object(properties: [:])) { _ in
        started.yield()
        for _ in 0..<500 {
            try Task.checkCancellation()
            await AsyncTimeout.sleep(.milliseconds(20))
        }
        return [.plainText(#"{"finished":true}"#)]
    }
}

private func makeTransport(
    configuration: HTTPTransport.Configuration = .init(requestTimeout: .seconds(5), cleanupInterval: .milliseconds(20))
) -> HTTPTransport {
    HTTPTransport(
        host: "127.0.0.1",
        port: 0,
        catalog: ToolCatalog([]),
        setupPermissions: SetupPermissionService(
            contactsRequest: { (false, .notDetermined) },
            automationRequest: { (false, .notDetermined) }
        ),
        configuration: configuration
    )
}

private func openSession(_ client: some TestClientProtocol) async throws -> String {
    var fields = HTTPFields()
    fields[.contentType] = "application/json"
    fields[.accept] = "application/json, text/event-stream"
    let response = try await client.executeRequest(
        uri: "/", method: .post, headers: fields,
        body: ByteBuffer(
            string: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}}}"#
        )
    )
    return try XCTUnwrap(response.head.headerFields[HTTPField.Name(MCPHeader.sessionID)!])
}

private func headers(sessionId: String) -> HTTPFields {
    var fields = HTTPFields()
    fields[.contentType] = "application/json"
    fields[.accept] = "application/json, text/event-stream"
    fields[HTTPField.Name(MCPHeader.sessionID)!] = sessionId
    return fields
}

private func object(_ body: ByteBuffer) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any])
}

private struct Review2SlowMethod: MCP.Method {
    static let name = "tests/review2-slow"

    struct Parameters: Codable, Hashable, Sendable {}
    struct Result: Codable, Hashable, Sendable {}
}

/// A base transport fed one line at a time, recording writes.
private actor FeedableBaseTransport: Transport {
    nonisolated let logger = Logger(label: "test.feedable-base", factory: { _ in SwiftLogNoOpLogHandler() })
    private var sent: [Data] = []
    private var waiters: [CheckedContinuation<Data, Never>] = []
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init() {
        (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
    }

    func connect() async throws {}

    func disconnect() async {
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        sent.append(data)
        let due = waiters
        waiters.removeAll()
        due.forEach { $0.resume(returning: sent[0]) }
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func feed(_ line: String) {
        continuation.yield(Data(line.utf8))
    }

    func firstSent() async -> Data {
        if let first = sent.first { return first }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
