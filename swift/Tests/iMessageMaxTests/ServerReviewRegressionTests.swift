import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import IMessageMaxContract
import Logging
import MCP
import NIOCore
import Synchronization
import XCTest
@testable import iMessageMax

/// Regression tests for the server-transport review fixes. Self-contained:
/// every helper lives in this file.
final class ServerReviewRegressionTests: XCTestCase {

    // MARK: - Legacy HTTP tools/call shortcut

    /// A `notifications/cancelled` POST stops a legacy HTTP `tools/call`
    /// that the shortcut answers, and the call replies with its cancelled
    /// result, as on stdio. Before the fix the notification went to the
    /// session's SDK Server, which never saw the request, and the call ran on.
    func testCancelledNotificationStopsLegacyHTTPToolCall() async throws {
        let (started, startedSink) = AsyncStream<Void>.makeStream()
        let catalog = ToolCatalog([
            ToolDefinition(name: "wait_for_cancel", description: "", inputSchema: InputSchema.object(properties: [:])) { _ in
                startedSink.yield()
                for _ in 0..<500 {
                    try Task.checkCancellation()
                    await AsyncTimeout.sleep(.milliseconds(20))
                }
                return [.plainText(#"{"finished":true}"#)]
            },
        ])
        let transport = makeTransport(catalog: catalog)
        let app = await transport.application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await openSession(client)
            let clock = ContinuousClock()
            let begin = clock.now

            async let call = client.executeRequest(
                uri: "/", method: .post, headers: headers(sessionId: sessionId),
                body: buffer(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"wait_for_cancel","arguments":{}}}"#)
            )
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()

            let cancel = try await client.executeRequest(
                uri: "/", method: .post, headers: headers(sessionId: sessionId),
                body: buffer(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"test"}}"#)
            )
            XCTAssertEqual(cancel.head.status, .accepted)

            let response = try await call
            XCTAssertLessThan(clock.now - begin, .seconds(5), "the call ran to completion instead of stopping")
            let json = try object(response.body)
            XCTAssertEqual(json["id"] as? Int, 7)
            let result = try XCTUnwrap(json["result"] as? [String: Any], "\(json)")
            XCTAssertEqual(result["isError"] as? Bool, true)
            XCTAssertNil(result["structuredContent"])
        }
    }

    /// The legacy HTTP unknown-tool error is the SDK's own encoding of the
    /// `MCPError` the stdio lane throws.
    func testLegacyHTTPUnknownToolErrorIsTheSDKEncoding() async throws {
        let transport = makeTransport(catalog: ToolCatalog([]))
        let app = await transport.application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await openSession(client)
            let response = try await client.executeRequest(
                uri: "/", method: .post, headers: headers(sessionId: sessionId),
                body: buffer(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#)
            )
            let error = try XCTUnwrap(try object(response.body)["error"] as? [String: Any])
            let expected = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(ToolCallDispatch.unknownToolError("nope"))) as? [String: Any]
            )
            XCTAssertEqual(error as NSDictionary, expected as NSDictionary)
            XCTAssertEqual(error["code"] as? Int, -32601)
            XCTAssertEqual(error["message"] as? String, "Method not found: Unknown tool: nope")
        }
    }

    /// Non-object `arguments` never run the tool on its defaults: legacy
    /// HTTP hands the call to the SDK, which refuses it, and the modern lane
    /// answers invalid params.
    func testNonObjectArgumentsAreRefusedOnBothHTTPLanes() async throws {
        let ran = Mutex(0)
        let catalog = ToolCatalog([
            ToolDefinition(name: "probe", description: "", inputSchema: InputSchema.object(properties: [:])) { _ in
                ran.withLock { $0 += 1 }
                return [.plainText("{}")]
            },
        ])
        let transport = makeTransport(catalog: catalog)
        let app = await transport.application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await openSession(client)
            for arguments in [#"[1,2]"#, #""text""#, "7"] {
                let legacy = try await client.executeRequest(
                    uri: "/", method: .post, headers: headers(sessionId: sessionId),
                    body: buffer(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"probe","arguments":\#(arguments)}}"#)
                )
                let legacyJSON = try object(legacy.body)
                XCTAssertNotNil(legacyJSON["error"], "legacy, arguments \(arguments): \(legacyJSON)")
                XCTAssertNil(legacyJSON["result"], "legacy, arguments \(arguments)")

                var modernHeaders = HTTPFields()
                modernHeaders[.contentType] = "application/json"
                modernHeaders[.accept] = "application/json, text/event-stream"
                modernHeaders[HTTPField.Name(MCPHeader.protocolVersion)!] = ModernMCP.protocolVersion
                modernHeaders[HTTPField.Name(MCPHeader.method)!] = "tools/call"
                modernHeaders[HTTPField.Name(MCPHeader.name)!] = "probe"
                let modern = try await client.executeRequest(
                    uri: "/", method: .post, headers: modernHeaders,
                    body: buffer(
                        #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"probe","arguments":\#(arguments),"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
                    )
                )
                XCTAssertEqual(modern.head.status, .badRequest)
                let modernError = try XCTUnwrap(try object(modern.body)["error"] as? [String: Any])
                XCTAssertEqual(modernError["code"] as? Int, JSONRPCErrorCode.invalidParams.rawValue)
            }

            // `arguments: null` and an absent `arguments` still run the tool.
            let nullArguments = try await client.executeRequest(
                uri: "/", method: .post, headers: headers(sessionId: sessionId),
                body: buffer(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"probe","arguments":null}}"#)
            )
            XCTAssertNotNil(try object(nullArguments.body)["result"])
        }
        XCTAssertEqual(ran.withLock { $0 }, 1)
    }

    // MARK: - Server-initiated messages

    /// A server-initiated request whose id equals a waiting POST's id goes
    /// to SSE; only the response completes the POST.
    func testServerRequestWithClientIdDoesNotCompleteWaitingPost() async throws {
        let (started, startedSink) = AsyncStream<Void>.makeStream()
        var configuration = HTTPTransport.Configuration(requestTimeout: .seconds(5), cleanupInterval: .milliseconds(20))
        configuration.makeServer = { catalog in
            let server = await Version.makeServer(catalog: catalog)
            await server.withMethodHandler(ReviewSlowMethod.self) { _ in
                startedSink.yield()
                await AsyncTimeout.sleep(.milliseconds(300))
                return .init(source: "handler")
            }
            return server
        }
        let transport = makeTransport(catalog: ToolCatalog([]), configuration: configuration)
        let app = await transport.application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await openSession(client)
            async let call = client.executeRequest(
                uri: "/", method: .post, headers: headers(sessionId: sessionId),
                body: buffer(#"{"jsonrpc":"2.0","id":"shared","method":"tests/review-slow","params":{}}"#)
            )
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()

            await transport.handleServerResponse(
                sessionId: sessionId,
                data: Data(#"{"jsonrpc":"2.0","id":"shared","method":"roots/list","params":{}}"#.utf8)
            )

            let json = try object(try await call.body)
            let result = try XCTUnwrap(json["result"] as? [String: Any], "\(json)")
            XCTAssertEqual(result["source"] as? String, "handler")
        }
    }

    // MARK: - stdio drain

    /// A modern request followed by end of input is answered before the
    /// stdio server returns. Before the fix the server returned when the SDK
    /// Server completed, while the modern reply was still being produced.
    func testStdioWritesModernReplyBeforeReturningAtEndOfInput() async throws {
        let catalog = ToolCatalog([
            ToolDefinition(name: "slow", description: "", inputSchema: InputSchema.object(properties: [:])) { _ in
                await AsyncTimeout.sleep(.milliseconds(300))
                return [.plainText(#"{"done":true}"#)]
            },
        ])
        let base = ScriptedBaseTransport(input: [
            Data(
                #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"slow","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
                    .utf8
            ),
        ])

        try await ServerStartup.serveStdio(base: base, catalog: catalog)

        let sent = await base.sent
        let replies = sent.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let reply = try XCTUnwrap(replies.first { $0["id"] as? Int == 9 }, "no reply written: \(replies)")
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["done"] as? Bool, true)
    }

    // MARK: - Pure rules

    func testStructuredContentIsOnlyEverAnObject() {
        XCTAssertNotNil(ToolCallDispatch.structuredContent(from: [.plainText(#"{"a":1}"#)]))
        XCTAssertNil(ToolCallDispatch.structuredContent(from: [.plainText("[1,2]")]))
        XCTAssertNil(ToolCallDispatch.structuredContent(from: [.plainText(#""text""#)]))
        XCTAssertNil(ToolCallDispatch.structuredContent(from: [.plainText("{}"), .plainText("{}")]))
    }

    func testVersionGatesFollowRevisionDates() {
        XCTAssertFalse(LegacyProtocol.requiresHeaderAfterInitialize("2025-03-26"))
        XCTAssertTrue(LegacyProtocol.requiresHeaderAfterInitialize("2025-06-18"))
        XCTAssertTrue(LegacyProtocol.requiresHeaderAfterInitialize(LegacyProtocol.latest))
        XCTAssertTrue(LegacyProtocol.requiresHeaderAfterInitialize("2026-03-01"))

        XCTAssertFalse(LegacyProtocol.definesServerIcons("2025-06-18"))
        XCTAssertTrue(LegacyProtocol.definesServerIcons("2025-11-25"))
        XCTAssertTrue(LegacyProtocol.definesServerIcons("2026-03-01"))

        // A revision newer than today's latest still gets icons.
        let initialize = Data(
            #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2026-03-01","serverInfo":{"name":"x","version":"1"},"capabilities":{}}}"#.utf8
        )
        let injected = IconMetadata.injectServerIcons(into: initialize)
        let serverInfo = (try? JSONSerialization.jsonObject(with: injected) as? [String: Any])
            .flatMap { $0["result"] as? [String: Any] }
            .flatMap { $0["serverInfo"] as? [String: Any] }
        XCTAssertNotNil(serverInfo?["icons"])
    }

    func testSDKErrorEnvelopeMatchesSDKEncoding() throws {
        let data = JSONRPC.error(id: 1, MCPError.invalidParams("bad"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual(error["message"] as? String, "Invalid params: bad")
        XCTAssertEqual((error["data"] as? [String: Any])?["detail"] as? String, "bad")
        XCTAssertEqual(json["id"] as? Int, 1)
    }
}

// MARK: - Helpers

private func makeTransport(
    catalog: ToolCatalog,
    configuration: HTTPTransport.Configuration = .init(requestTimeout: .seconds(5), cleanupInterval: .milliseconds(20))
) -> HTTPTransport {
    HTTPTransport(
        host: "127.0.0.1",
        port: 0,
        catalog: catalog,
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
        body: buffer(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}}}"#
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

private func buffer(_ text: String) -> ByteBuffer {
    ByteBuffer(string: text)
}

private func object(_ body: ByteBuffer) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any])
}

private struct ReviewSlowMethod: MCP.Method {
    static let name = "tests/review-slow"

    struct Parameters: Codable, Hashable, Sendable {}

    struct Result: Codable, Hashable, Sendable {
        let source: String
    }
}

/// A base transport that delivers `input`, then ends, and records writes.
private actor ScriptedBaseTransport: Transport {
    nonisolated let logger = Logger(label: "test.scripted-base", factory: { _ in SwiftLogNoOpLogHandler() })
    private let input: [Data]
    private(set) var sent: [Data] = []

    init(input: [Data]) {
        self.input = input
    }

    func connect() async throws {}

    func disconnect() async {}

    func send(_ data: Data) async throws {
        sent.append(data)
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        let input = self.input
        return AsyncThrowingStream { continuation in
            for data in input {
                continuation.yield(data)
            }
            continuation.finish()
        }
    }
}
