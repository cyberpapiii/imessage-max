import XCTest
import MCP
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Synchronization
@testable import iMessageMax

final class HTTPTransportIntegrationTests: XCTestCase {
    func testInitializeCreatesSessionIdAndImmediateToolsList() async throws {
        let app = await makeTestTransport().application()

        try await app.test(TestingSetup.router) { client in
            let initializeResponse = try await client.post(initializeBody(protocolVersion: "2025-11-25"))

            XCTAssertEqual(initializeResponse.head.status, .ok, String(buffer: initializeResponse.body))
            let initializeResult = try XCTUnwrap(try decodeJSON(from: initializeResponse.body)["result"] as? [String: Any])
            XCTAssertEqual(initializeResult["protocolVersion"] as? String, "2025-11-25")
            XCTAssertNotNil(initializeResult["instructions"])
            let serverInfo = try XCTUnwrap(initializeResult["serverInfo"] as? [String: Any])
            XCTAssertEqual(serverInfo["title"] as? String, "iMessage Max")
            assertIconMetadata(serverInfo["icons"], context: "serverInfo")
            let capabilities = try XCTUnwrap(initializeResult["capabilities"] as? [String: Any])
            XCTAssertNotNil(capabilities["tools"])
            let sessionId = try XCTUnwrap(initializeResponse.head.headerFields[.mcpSessionId])
            XCTAssertFalse(sessionId.isEmpty)

            let toolsResponse = try await client.post(
                toolsListBody(id: 2), headers: jsonHeaders(sessionId: sessionId, protocolVersion: "2025-11-25")
            )

            XCTAssertEqual(toolsResponse.head.status, .ok)
            let result = try XCTUnwrap(try decodeJSON(from: toolsResponse.body)["result"] as? [String: Any])
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 13)
            XCTAssertTrue(tools.contains { $0["name"] as? String == "send" })
            XCTAssertTrue(tools.contains { $0["name"] as? String == "diagnose" })
            XCTAssertTrue(tools.contains { $0["name"] as? String == "get_chat_details" })
            for tool in tools {
                XCTAssertNotNil(tool["title"], "\(tool["name"] ?? "unknown") missing title")
                assertIconMetadata(
                    tool["icons"],
                    context: "\(tool["name"] ?? "unknown") tool",
                    expectedSizes: ["16x16"]
                )
                if tool["name"] as? String != "get_attachment" {
                    XCTAssertNotNil(tool["outputSchema"], "\(tool["name"] ?? "unknown") missing outputSchema")
                }
            }
        }
    }

    func testLegacyProtocolDoesNotReceiveIconMetadata() async throws {
        let app = await makeTestTransport().application()

        try await app.test(TestingSetup.router) { client in
            let initializeResponse = try await client.post(initializeBody(protocolVersion: "2025-03-26"))

            XCTAssertEqual(initializeResponse.head.status, .ok)
            let initializeResult = try XCTUnwrap(try decodeJSON(from: initializeResponse.body)["result"] as? [String: Any])
            XCTAssertEqual(initializeResult["protocolVersion"] as? String, "2025-03-26")
            let serverInfo = try XCTUnwrap(initializeResult["serverInfo"] as? [String: Any])
            XCTAssertNil(serverInfo["icons"])
        }
    }

    func testLatestProtocolRequiresVersionHeaderAfterInitialize() async throws {
        let app = await makeTestTransport().application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession(protocolVersion: "2025-11-25")

            let missingHeaderResponse = try await client.post(toolsListBody(id: 2), headers: jsonHeaders(sessionId: sessionId))
            XCTAssertEqual(missingHeaderResponse.head.status, .badRequest)
            XCTAssertTrue(try decodeJSONString(from: missingHeaderResponse.body).contains("MCP-Protocol-Version"))

            let mismatchedHeaderResponse = try await client.post(
                toolsListBody(id: 3), headers: jsonHeaders(sessionId: sessionId, protocolVersion: "2025-06-18")
            )
            XCTAssertEqual(mismatchedHeaderResponse.head.status, .badRequest)
        }
    }

    func testPostAcceptHeaderMustAdvertiseJsonAndEventStream() async throws {
        let app = await makeTestTransport().application()

        try await app.test(TestingSetup.router) { client in
            let response = try await client.post(
                initializeBody(), headers: [.contentType: "application/json", .accept: "application/json"]
            )

            XCTAssertEqual(response.head.status, .notAcceptable)
        }
    }

    func testJsonToolCallsReturnStructuredContentAndLegacyText() async throws {
        let app = await makeTestTransport().application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession(protocolVersion: "2025-11-25")
            let response = try await client.post(
                #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"diagnose","arguments":{}}}"#,
                headers: jsonHeaders(sessionId: sessionId, protocolVersion: "2025-11-25")
            )

            XCTAssertEqual(response.head.status, .ok)
            let result = try XCTUnwrap(try decodeJSON(from: response.body)["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            XCTAssertEqual(content.first?["type"] as? String, "text")
            XCTAssertNotNil(result["structuredContent"])
        }
    }

    func testLegacyToolCallEnvelopeMatchesTheSDK() async throws {
        let app = await makeTestTransport().application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession(protocolVersion: "2025-11-25")
            let headers = jsonHeaders(sessionId: sessionId, protocolVersion: "2025-11-25")

            let failing = try await client.post(
                #"{"jsonrpc":"2.0","id":"str-id","method":"tools/call","params":{"name":"find_chat","arguments":{}}}"#,
                headers: headers
            )
            XCTAssertEqual(failing.head.status, .ok)
            let failingBody = try decodeJSON(from: failing.body)
            XCTAssertEqual(failingBody["id"] as? String, "str-id")
            let failingResult = try XCTUnwrap(failingBody["result"] as? [String: Any])
            XCTAssertEqual(failingResult["isError"] as? Bool, true)
            XCTAssertNil(failingResult["structuredContent"])
            let failingContent = try XCTUnwrap(failingResult["content"] as? [[String: Any]])
            XCTAssertEqual(failingContent.first?["type"] as? String, "text")

            let unknown = try await client.post(
                #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}"#,
                headers: headers
            )
            XCTAssertEqual(unknown.head.status, .ok)
            let unknownBody = try decodeJSON(from: unknown.body)
            XCTAssertNil(unknownBody["result"])
            let error = try XCTUnwrap(unknownBody["error"] as? [String: Any])
            let expected: [String: Any] = [
                "code": -32601,
                "message": "Method not found: Unknown tool: no_such_tool",
                "data": ["detail": "Unknown tool: no_such_tool"],
            ]
            XCTAssertEqual(error as NSDictionary, expected as NSDictionary)
        }
    }

    func testCancelledNotificationStopsLegacyToolCall() async throws {
        let (started, startedSink) = AsyncStream<Void>.makeStream()
        let app = await makeTestTransport(catalog: ToolCatalog([waitForCancelTool(started: startedSink)])).application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession()
            let clock = ContinuousClock()
            let begin = clock.now

            async let call = client.post(
                #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"wait_for_cancel","arguments":{}}}"#,
                headers: jsonHeaders(sessionId: sessionId)
            )
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()

            let cancel = try await client.post(
                #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"test"}}"#,
                headers: jsonHeaders(sessionId: sessionId)
            )
            XCTAssertEqual(cancel.head.status, .accepted)

            let response = try await call
            XCTAssertLessThan(clock.now - begin, .seconds(5), "the call ran to completion instead of stopping")
            let json = try decodeJSON(from: response.body)
            XCTAssertEqual(json["id"] as? Int, 7)
            let result = try XCTUnwrap(json["result"] as? [String: Any], "\(json)")
            XCTAssertEqual(result["isError"] as? Bool, true)
            XCTAssertNil(result["structuredContent"])
        }
    }

    func testNonObjectArgumentsAreRefusedOnBothLanes() async throws {
        let ran = Mutex(0)
        let probe = fakeTool(named: "probe") { _ in
            ran.withLock { $0 += 1 }
            return [.plainText("{}")]
        }
        let app = await makeTestTransport(catalog: ToolCatalog([probe])).application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession()
            for arguments in [#"[1,2]"#, #""text""#, "7"] {
                let legacy = try await client.post(
                    #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"probe","arguments":\#(arguments)}}"#,
                    headers: jsonHeaders(sessionId: sessionId)
                )
                let legacyJSON = try decodeJSON(from: legacy.body)
                XCTAssertNotNil(legacyJSON["error"], "legacy, arguments \(arguments): \(legacyJSON)")
                XCTAssertNil(legacyJSON["result"], "legacy, arguments \(arguments)")

                let modern = try await client.post(
                    modernBody(id: 5, method: "tools/call", params: #""name":"probe","arguments":\#(arguments)"#),
                    headers: modernHeaders(method: "tools/call", name: "probe")
                )
                XCTAssertEqual(modern.head.status, .badRequest)
                let modernError = try XCTUnwrap(try decodeJSON(from: modern.body)["error"] as? [String: Any])
                XCTAssertEqual(modernError["code"] as? Int, -32602)
            }

            let nullArguments = try await client.post(
                #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"probe","arguments":null}}"#,
                headers: jsonHeaders(sessionId: sessionId)
            )
            XCTAssertNotNil(try decodeJSON(from: nullArguments.body)["result"])
            let absentArguments = try await client.post(
                #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"probe"}}"#,
                headers: jsonHeaders(sessionId: sessionId)
            )
            XCTAssertNotNil(try decodeJSON(from: absentArguments.body)["result"])
        }
        XCTAssertEqual(ran.withLock { $0 }, 2)
    }

    func testInvalidSessionReturnsNotFound() async throws {
        let app = await makeTestTransport().application()

        try await app.test(TestingSetup.router) { client in
            let response = try await client.post(toolsListBody(id: 99), headers: jsonHeaders(sessionId: "missing-session"))

            XCTAssertEqual(response.head.status, .notFound)
            XCTAssertTrue(try decodeJSONString(from: response.body).contains("Invalid or expired session"))
        }
    }

    func testRequestTrackingIsScopedPerSessionEvenWithSameJsonRpcId() async throws {
        var configuration = HTTPTransport.Configuration.test
        configuration.requestTimeout = .seconds(2)
        configuration.makeServer = serversWithSlowMethod(
            [("session-a", .zero), ("session-b", .zero)],
            rendezvous: Rendezvous(parties: 2)
        )
        let app = await makeTestTransport(configuration: configuration).application()

        try await app.test(TestingSetup.router) { client in
            let sessionA = try await client.initializeSession()
            let sessionB = try await client.initializeSession()

            async let responseA = client.post(slowMethodBody(id: "shared-id"), headers: jsonHeaders(sessionId: sessionA))
            async let responseB = client.post(slowMethodBody(id: "shared-id"), headers: jsonHeaders(sessionId: sessionB))
            let (resultA, resultB) = try await (responseA, responseB)

            XCTAssertEqual(resultA.head.status, .ok)
            XCTAssertEqual(resultB.head.status, .ok)
            XCTAssertEqual(try slowMethodSource(from: resultA.body), "session-a")
            XCTAssertEqual(try slowMethodSource(from: resultB.body), "session-b")
        }
    }

    func testDuplicateInFlightIdIsA400CarryingTheId() async throws {
        let rendezvous = Rendezvous(parties: 2)
        var configuration = HTTPTransport.Configuration.test
        configuration.makeServer = serversWithSlowMethod([("first", .milliseconds(300))], rendezvous: rendezvous)
        let app = await makeTestTransport(configuration: configuration).application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession()
            async let first = client.post(slowMethodBody(id: "dup"), headers: jsonHeaders(sessionId: sessionId))
            await rendezvous.arrive()

            let second = try await client.post(slowMethodBody(id: "dup"), headers: jsonHeaders(sessionId: sessionId))
            XCTAssertEqual(second.head.status, .badRequest)
            let json = try decodeJSON(from: second.body)
            XCTAssertEqual(json["id"] as? String, "dup")
            XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? Int, -32600)

            let firstStatus = try await first.head.status
            XCTAssertEqual(firstStatus, .ok)
        }
    }

    func testNonScalarIdIsA400() async throws {
        let app = await makeTestTransport().application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession()
            let response = try await client.post(
                #"{"jsonrpc":"2.0","id":{"a":1},"method":"tools/list","params":{}}"#,
                headers: jsonHeaders(sessionId: sessionId)
            )
            XCTAssertEqual(response.head.status, .badRequest)
            let json = try decodeJSON(from: response.body)
            XCTAssertTrue(json["id"] is NSNull)
            XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? Int, -32600)
        }
    }

    func testNonScalarIdOnTheToolsCallShortcutIsA400() async throws {
        let app = await makeTestTransport(catalog: ToolCatalog([])).application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession()
            for body in [
                #"{"jsonrpc":"2.0","id":{"a":1},"method":"tools/call","params":{"name":"anything","arguments":{}}}"#,
                #"{"jsonrpc":"2.0","id":{"a":1},"method":"tools/list","params":{}}"#,
            ] {
                let response = try await client.post(body, headers: jsonHeaders(sessionId: sessionId))
                XCTAssertEqual(response.head.status, .badRequest, body)
                let json = try decodeJSON(from: response.body)
                XCTAssertTrue(json["id"] is NSNull, body)
                XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? Int, -32600, body)
            }
        }
    }

    func testInFlightIdOnTheToolsCallShortcutIsA400CarryingTheId() async throws {
        let (started, startedSink) = AsyncStream<Void>.makeStream()
        let slow = fakeTool(named: "slow") { _ in
            startedSink.yield()
            await AsyncTimeout.sleep(.milliseconds(300))
            return [.plainText(#"{"done":true}"#)]
        }
        let app = await makeTestTransport(catalog: ToolCatalog([slow])).application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession()
            let call = #"{"jsonrpc":"2.0","id":"dup","method":"tools/call","params":{"name":"slow","arguments":{}}}"#
            async let first = client.post(call, headers: jsonHeaders(sessionId: sessionId))
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()

            for body in [call, #"{"jsonrpc":"2.0","id":"dup","method":"tools/list","params":{}}"#] {
                let second = try await client.post(body, headers: jsonHeaders(sessionId: sessionId))
                XCTAssertEqual(second.head.status, .badRequest, body)
                let json = try decodeJSON(from: second.body)
                XCTAssertEqual(json["id"] as? String, "dup", body)
                XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? Int, -32600, body)
            }
            let firstStatus = try await first.head.status
            XCTAssertEqual(firstStatus, .ok)
        }
    }

    func testServerRequestWithClientIdDoesNotCompleteWaitingPost() async throws {
        let rendezvous = Rendezvous(parties: 2)
        var configuration = HTTPTransport.Configuration.test
        configuration.makeServer = serversWithSlowMethod([("handler", .milliseconds(300))], rendezvous: rendezvous)
        let transport = makeTestTransport(configuration: configuration)
        let app = await transport.application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession()
            async let call = client.post(slowMethodBody(id: "shared"), headers: jsonHeaders(sessionId: sessionId))
            await rendezvous.arrive()

            await transport.handleServerResponse(
                sessionId: sessionId,
                data: Data(#"{"jsonrpc":"2.0","id":"shared","method":"roots/list","params":{}}"#.utf8)
            )

            let response = try await call
            XCTAssertEqual(try slowMethodSource(from: response.body), "handler")
        }
    }

    func testCompletedRequestsDoNotLeaveCrashingTimeoutTasks() async throws {
        var configuration = HTTPTransport.Configuration.test
        configuration.requestTimeout = .milliseconds(200)
        let app = await makeTestTransport(configuration: configuration).application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession()

            let firstResponse = try await client.post(toolsListBody(id: 2), headers: jsonHeaders(sessionId: sessionId))
            XCTAssertEqual(firstResponse.head.status, .ok)

            try await Task.sleep(for: .milliseconds(300))

            let secondResponse = try await client.post(toolsListBody(id: 3), headers: jsonHeaders(sessionId: sessionId))
            XCTAssertEqual(secondResponse.head.status, .ok)
        }
    }

    func testRequestTimeoutFiresWhenHandlerNeverResponds() async throws {
        var configuration = HTTPTransport.Configuration.test
        configuration.requestTimeout = .milliseconds(200)
        configuration.makeServer = serversWithSlowMethod([("too-late", .seconds(2))])
        let app = await makeTestTransport(configuration: configuration).application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession()

            let start = ContinuousClock().now
            let response = try await client.post(slowMethodBody(id: "timeout-probe"), headers: jsonHeaders(sessionId: sessionId))
            let elapsed = ContinuousClock().now - start

            XCTAssertEqual(response.head.status, .internalServerError)
            XCTAssertLessThan(elapsed, .seconds(2), "timeout must fire before the stuck handler completes")
        }
    }

    func testHugeJsonRpcIdDoesNotCrashTheServer() async throws {
        let app = await makeTestTransport().application()

        try await app.test(TestingSetup.router) { client in
            _ = try await client.post(
                #"{"jsonrpc":"2.0","id":1e300,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}}}"#
            )

            let normalResponse = try await client.post(initializeBody())
            XCTAssertEqual(normalResponse.head.status, .ok)
        }
    }

    func testMaliciousProtocolVersionHeaderYieldsWellFormedJson() async throws {
        let app = await makeTestTransport().application()

        try await app.test(TestingSetup.router) { client in
            let maliciousVersion = #"bad\version"x"#
            let response = try await client.post(initializeBody(), headers: jsonHeaders(protocolVersion: maliciousVersion))

            XCTAssertEqual(response.head.status, .badRequest)
            let json = try decodeJSON(from: response.body)
            let error = try XCTUnwrap(json["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32600)
            let message = try XCTUnwrap(error["message"] as? String)
            XCTAssertTrue(message.contains(maliciousVersion), "Expected the raw header echoed back safely, got \(message)")
        }
    }

    func testSSEGetRejectsMissingEventStreamAccept() async throws {
        let app = await makeTestTransport().application()

        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(
                uri: "/", method: .get, headers: [.accept: "application/json"], body: nil
            )

            let body = try decodeJSONString(from: response.body)
            XCTAssertEqual(response.head.status, .notAcceptable, body)
            XCTAssertTrue(body.contains("Invalid Accept header"), body)
        }
    }

    func testSSEGetRejectsMissingSessionHeader() async throws {
        let app = await makeTestTransport().application()

        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(
                uri: "/", method: .get, headers: [.accept: "text/event-stream"], body: nil
            )

            let body = try decodeJSONString(from: response.body)
            XCTAssertEqual(response.head.status, .badRequest, body)
            XCTAssertTrue(body.contains("Missing Mcp-Session-Id header"), body)
        }
    }

    func testSSEGetRejectsUnknownSession() async throws {
        let app = await makeTestTransport().application()

        try await app.test(TestingSetup.router) { client in
            var headers: HTTPFields = [.accept: "text/event-stream"]
            headers[.mcpSessionId] = "not-a-real-session"

            let response = try await client.executeRequest(uri: "/", method: .get, headers: headers, body: nil)

            let body = try decodeJSONString(from: response.body)
            XCTAssertEqual(response.head.status, .notFound, body)
            XCTAssertTrue(body.contains("Invalid or expired session"), body)
        }
    }

    /// The GET calls `handleGet` directly, not through the test client: the
    /// client writes the whole response body before it returns, and an open
    /// SSE body never ends, so the request would hang the suite. The head is
    /// complete when `handleGet` returns.
    func testSSEGetOpensStreamForLiveSession() async throws {
        let transport = makeTestTransport()
        let app = await transport.application()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession()

            var headers: HTTPFields = [.accept: "text/event-stream"]
            headers[.mcpSessionId] = sessionId
            let request = Request(
                head: .init(method: .get, scheme: "http", authority: "localhost", path: "/", headerFields: headers),
                body: .init(buffer: ByteBuffer())
            )
            let response = await transport.handleGet(request: request)

            XCTAssertEqual(response.head.status, .ok)
            let contentType = response.head.headerFields[.contentType]
            XCTAssertTrue(
                contentType?.contains("text/event-stream") == true,
                "unexpected Content-Type: \(contentType ?? "nil")"
            )
            XCTAssertEqual(response.head.headerFields[.cacheControl], "no-cache")
            XCTAssertEqual(response.head.headerFields[.mcpSessionId], sessionId)
        }
    }

    func testSecondSessionAtCapacityReturns503() async throws {
        var configuration = HTTPTransport.Configuration.test
        configuration.maxSessions = 1
        let app = await makeTestTransport(configuration: configuration).application()

        try await app.test(TestingSetup.router) { client in
            let firstSessionId = try await client.initializeSession()
            XCTAssertFalse(firstSessionId.isEmpty)

            let secondResponse = try await client.post(initializeBody(id: 2))
            let secondBody = try decodeJSONString(from: secondResponse.body)
            XCTAssertEqual(secondResponse.head.status, .serviceUnavailable, secondBody)
            XCTAssertTrue(secondBody.contains("Session capacity reached"), secondBody)
            XCTAssertTrue(secondBody.contains("Reuse an existing session"), secondBody)
            XCTAssertTrue(secondBody.contains("DELETE"), secondBody)
            XCTAssertTrue(secondBody.contains("Mcp-Session-Id"), secondBody)
            XCTAssertTrue(secondBody.contains("idle sessions expire"), secondBody)

            let deleteResponse = try await client.executeRequest(
                uri: "/", method: .delete, headers: jsonHeaders(sessionId: firstSessionId), body: ByteBuffer()
            )
            XCTAssertEqual(deleteResponse.head.status, .noContent)

            let recoveredResponse = try await client.post(initializeBody(id: 3))
            XCTAssertEqual(recoveredResponse.head.status, .ok, String(buffer: recoveredResponse.body))
        }
    }
}

private struct TestSlowMethod: MCP.Method {
    static let name = "tests/slow"

    struct Parameters: Codable, Hashable, Sendable {
        let token: String
    }

    struct Result: Codable, Hashable, Sendable {
        let source: String
    }
}

private func serversWithSlowMethod(
    _ answers: [(source: String, delay: Duration)],
    rendezvous: Rendezvous? = nil
) -> @Sendable (ToolCatalog) async -> Server {
    let created = Mutex(0)
    return { catalog in
        let server = await Version.makeServer(catalog: catalog)
        let index = created.withLock { count in
            defer { count += 1 }
            return min(count, answers.count - 1)
        }
        let (source, delay) = answers[index]
        await server.withMethodHandler(TestSlowMethod.self) { _ in
            await rendezvous?.arrive()
            try await Task.sleep(for: delay)
            return .init(source: source)
        }
        return server
    }
}

private actor Rendezvous {
    private let parties: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(parties: Int) { self.parties = parties }

    func arrive() async {
        if waiting.count + 1 == parties {
            waiting.forEach { $0.resume() }
            waiting.removeAll()
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }
}

private func toolsListBody(id: Int) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/list","params":{}}"#
}

private func slowMethodBody(id: String) -> String {
    #"{"jsonrpc":"2.0","id":"\#(id)","method":"\#(TestSlowMethod.name)","params":{"token":"\#(id)"}}"#
}

private func slowMethodSource(from buffer: ByteBuffer) throws -> String {
    let result = try XCTUnwrap(try decodeJSON(from: buffer)["result"] as? [String: Any])
    return try XCTUnwrap(result["source"] as? String)
}

private func assertIconMetadata(
    _ value: Any?,
    context: String,
    expectedSizes: [String] = ["64x64", "32x32", "16x16"],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let icons = value as? [[String: Any]], !icons.isEmpty else {
        return XCTFail("\(context) missing icons", file: file, line: line)
    }
    let sizes = icons.compactMap { ($0["sizes"] as? [String])?.first }
    XCTAssertEqual(sizes, expectedSizes, file: file, line: line)

    let prefix = "data:image/png;base64,"
    for icon in icons {
        XCTAssertEqual(icon["mimeType"] as? String, "image/png", file: file, line: line)
        guard let src = icon["src"] as? String, src.hasPrefix(prefix) else {
            XCTFail("\(context) icon is not a PNG data URI", file: file, line: line)
            continue
        }
        guard let data = Data(base64Encoded: String(src.dropFirst(prefix.count))) else {
            XCTFail("\(context) icon base64 is invalid", file: file, line: line)
            continue
        }
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], file: file, line: line)
    }
}
