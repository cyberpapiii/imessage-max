import XCTest
import MCP
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import NIOEmbedded
@testable import iMessageMax

final class HTTPTransportIntegrationTests: XCTestCase {
    func testInitializeCreatesSessionIdAndImmediateToolsList() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            requestTimeout: .seconds(5),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let initializeResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(),
                body: byteBuffer(for: initializePayload(id: 1, protocolVersion: "2025-11-25"))
            )

            let initializeBody = try decodeJSONString(from: initializeResponse.body)
            XCTAssertEqual(initializeResponse.head.status, .ok, initializeBody)
            let initializeJSON = try decodeJSON(from: initializeResponse.body)
            let initializeResult = try XCTUnwrap(initializeJSON["result"] as? [String: Any])
            XCTAssertEqual(initializeResult["protocolVersion"] as? String, "2025-11-25")
            XCTAssertNotNil(initializeResult["instructions"])
            let serverInfo = try XCTUnwrap(initializeResult["serverInfo"] as? [String: Any])
            XCTAssertEqual(serverInfo["title"] as? String, "iMessage Max")
            assertIconMetadata(serverInfo["icons"], context: "serverInfo")
            let capabilities = try XCTUnwrap(initializeResult["capabilities"] as? [String: Any])
            XCTAssertNotNil(capabilities["tools"])
            let sessionId = try XCTUnwrap(initializeResponse.head.headerFields[.mcpSessionId])
            XCTAssertFalse(sessionId.isEmpty)

            let toolsResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(sessionId: sessionId, protocolVersion: "2025-11-25"),
                body: byteBuffer(for: toolsListPayload(id: 2))
            )

            XCTAssertEqual(toolsResponse.head.status, .ok)
            let body = try decodeJSON(from: toolsResponse.body)
            let result = try XCTUnwrap(body["result"] as? [String: Any])
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 12)
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
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(),
            requestTimeout: .seconds(5),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let initializeResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(),
                body: byteBuffer(for: initializePayload(id: 1, protocolVersion: "2025-03-26"))
            )

            let initializeJSON = try decodeJSON(from: initializeResponse.body)
            XCTAssertEqual(initializeResponse.head.status, .ok)
            let initializeResult = try XCTUnwrap(initializeJSON["result"] as? [String: Any])
            XCTAssertEqual(initializeResult["protocolVersion"] as? String, "2025-03-26")
            let serverInfo = try XCTUnwrap(initializeResult["serverInfo"] as? [String: Any])
            XCTAssertNil(serverInfo["icons"])
        }
    }

    func testLatestProtocolRequiresVersionHeaderAfterInitialize() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(),
            requestTimeout: .seconds(5),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await initializeSession(using: client, protocolVersion: "2025-11-25")

            let missingHeaderResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(sessionId: sessionId),
                body: byteBuffer(for: toolsListPayload(id: 2))
            )
            XCTAssertEqual(missingHeaderResponse.head.status, .badRequest)
            XCTAssertTrue(try decodeJSONString(from: missingHeaderResponse.body).contains("MCP-Protocol-Version"))

            let mismatchedHeaderResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(sessionId: sessionId, protocolVersion: "2025-06-18"),
                body: byteBuffer(for: toolsListPayload(id: 3))
            )
            XCTAssertEqual(mismatchedHeaderResponse.head.status, .badRequest)
        }
    }

    func testPostAcceptHeaderMustAdvertiseJsonAndEventStream() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(),
            requestTimeout: .seconds(5),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: [
                    .contentType: "application/json",
                    .accept: "application/json",
                ],
                body: byteBuffer(for: initializePayload(id: 1))
            )

            XCTAssertEqual(response.head.status, .notAcceptable)
        }
    }

    func testJsonToolCallsReturnStructuredContentAndLegacyText() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            requestTimeout: .seconds(5),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await initializeSession(using: client, protocolVersion: "2025-11-25")
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(sessionId: sessionId, protocolVersion: "2025-11-25"),
                body: byteBuffer(for: """
                    {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"diagnose","arguments":{}}}
                    """)
            )

            XCTAssertEqual(response.head.status, .ok)
            let body = try decodeJSON(from: response.body)
            let result = try XCTUnwrap(body["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            XCTAssertEqual(content.first?["type"] as? String, "text")
            XCTAssertNotNil(result["structuredContent"])
        }
    }

    func testLegacyToolCallEnvelopeSurvivesTheDirectDispatch() async throws {
        // tools/call no longer travels through the session's SDK Server, so
        // the three envelope shapes it used to produce are pinned here: a
        // failing tool, an unknown tool, and a preserved string id.
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            requestTimeout: .seconds(5),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await initializeSession(using: client, protocolVersion: "2025-11-25")

            // A tool that rejects its arguments answers with a result, not a
            // JSON-RPC error: isError true, no structuredContent.
            let failing = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(sessionId: sessionId, protocolVersion: "2025-11-25"),
                body: byteBuffer(for: """
                    {"jsonrpc":"2.0","id":"str-id","method":"tools/call","params":{"name":"find_chat","arguments":{}}}
                    """)
            )
            XCTAssertEqual(failing.head.status, .ok)
            let failingBody = try decodeJSON(from: failing.body)
            XCTAssertEqual(failingBody["id"] as? String, "str-id", "string ids must come back unchanged")
            let failingResult = try XCTUnwrap(failingBody["result"] as? [String: Any])
            XCTAssertEqual(failingResult["isError"] as? Bool, true)
            XCTAssertNil(failingResult["structuredContent"])
            let failingContent = try XCTUnwrap(failingResult["content"] as? [[String: Any]])
            XCTAssertEqual(failingContent.first?["type"] as? String, "text")

            // An unknown tool stays a method-not-found error.
            let unknown = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(sessionId: sessionId, protocolVersion: "2025-11-25"),
                body: byteBuffer(for: """
                    {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}
                    """)
            )
            XCTAssertEqual(unknown.head.status, .ok)
            let unknownBody = try decodeJSON(from: unknown.body)
            XCTAssertNil(unknownBody["result"])
            let error = try XCTUnwrap(unknownBody["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32601)
            let message = try XCTUnwrap(error["message"] as? String)
            XCTAssertTrue(message.contains("Unknown tool: no_such_tool"), message)
            let data = try XCTUnwrap(error["data"] as? [String: Any])
            XCTAssertEqual(data["detail"] as? String, "Unknown tool: no_such_tool")
        }
    }

    func testInvalidSessionReturnsNotFound() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(),
            requestTimeout: .seconds(5),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(sessionId: "missing-session"),
                body: byteBuffer(for: toolsListPayload(id: 99))
            )

            XCTAssertEqual(response.head.status, .notFound)
            let body = try decodeJSONString(from: response.body)
            XCTAssertTrue(body.contains("Invalid or expired session"))
        }
    }

    func testRequestTrackingIsScopedPerSessionEvenWithSameJsonRpcId() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(),
            requestTimeout: .seconds(2),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let sessionA = try await initializeSession(using: client)
            let sessionB = try await initializeSession(using: client)

            let didRegisterA = await transport.registerMethodHandlerForTesting(sessionId: sessionA, TestSlowMethod.self) { _ in
                try await Task.sleep(for: .milliseconds(20))
                return .init(source: "session-a")
            }
            XCTAssertTrue(didRegisterA)

            let didRegisterB = await transport.registerMethodHandlerForTesting(sessionId: sessionB, TestSlowMethod.self) { _ in
                try await Task.sleep(for: .milliseconds(40))
                return .init(source: "session-b")
            }
            XCTAssertTrue(didRegisterB)

            async let responseA = client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(sessionId: sessionA),
                body: byteBuffer(for: slowMethodPayload(id: "shared-id"))
            )
            async let responseB = client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(sessionId: sessionB),
                body: byteBuffer(for: slowMethodPayload(id: "shared-id"))
            )

            let (resultA, resultB) = try await (responseA, responseB)

            XCTAssertEqual(resultA.head.status, .ok)
            XCTAssertEqual(resultB.head.status, .ok)
            XCTAssertEqual(try slowMethodSource(from: resultA.body), "session-a")
            XCTAssertEqual(try slowMethodSource(from: resultB.body), "session-b")
        }
    }

    func testCompletedRequestsDoNotLeaveCrashingTimeoutTasks() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(),
            requestTimeout: .milliseconds(200),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await initializeSession(using: client)

            let firstResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(sessionId: sessionId),
                body: byteBuffer(for: toolsListPayload(id: 2))
            )
            XCTAssertEqual(firstResponse.head.status, .ok)

            try await Task.sleep(for: .milliseconds(300))

            let secondResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(sessionId: sessionId),
                body: byteBuffer(for: toolsListPayload(id: 3))
            )
            XCTAssertEqual(secondResponse.head.status, .ok)
        }
    }

    /// The request timeout must still fire now that the pending-request timer
    /// is a cancellable DispatchSourceTimer rather than asyncAfter.
    func testRequestTimeoutFiresWhenHandlerNeverResponds() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            requestTimeout: .milliseconds(200),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await initializeSession(using: client)

            let didRegister = await transport.registerMethodHandlerForTesting(sessionId: sessionId, TestSlowMethod.self) { _ in
                try await Task.sleep(for: .seconds(2))
                return .init(source: "too-late")
            }
            XCTAssertTrue(didRegister)

            let start = ContinuousClock().now
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(sessionId: sessionId),
                body: byteBuffer(for: slowMethodPayload(id: "timeout-probe"))
            )
            let elapsed = ContinuousClock().now - start

            XCTAssertEqual(response.head.status, .internalServerError)
            XCTAssertLessThan(elapsed, .seconds(2), "timeout must fire before the stuck handler completes")
        }
    }

    func testHugeJsonRpcIdDoesNotCrashTheServer() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            requestTimeout: .seconds(2),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            // `1e300` is a legal JSON number but outside Int's range. The old
            // id parser forced it through a non-failable Int conversion and
            // trapped, aborting the process on the first unauthenticated POST.
            let hugeIdPayload = """
                {"jsonrpc":"2.0","id":1e300,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}}}
                """

            let hugeResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(),
                body: byteBuffer(for: hugeIdPayload)
            )

            // Reaching this line at all is the regression test: any HTTP
            // status beats aborting the process.
            XCTAssertTrue(
                (100...599).contains(Int(hugeResponse.head.status.code)),
                "Expected a real HTTP status, got \(hugeResponse.head.status)"
            )

            // And the server is still serving afterwards.
            let normalResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(),
                body: byteBuffer(for: initializePayload(id: 1))
            )
            XCTAssertEqual(normalResponse.head.status, .ok)
        }
    }

    func testMaliciousProtocolVersionHeaderYieldsWellFormedJson() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            requestTimeout: .seconds(2),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            // Backslash + quote is the attack shape: HTTP/1.1 header values
            // cannot contain newlines, and the old builder escaped only `"`,
            // so a trailing backslash broke out of the JSON string.
            let maliciousVersion = #"bad\version"x"#
            var headers = jsonHeaders()
            headers[.mcpProtocolVersion] = maliciousVersion

            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: headers,
                body: byteBuffer(for: initializePayload(id: 1))
            )

            XCTAssertEqual(response.head.status, .badRequest)

            // decodeJSON parses with JSONSerialization, so it throws if the
            // body is malformed. That parse IS the injection assertion.
            let json = try decodeJSON(from: response.body)
            let error = try XCTUnwrap(json["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32600)

            // The value round-trips intact rather than being mangled or
            // truncated at the quote, proving it was encoded, not escaped.
            let message = try XCTUnwrap(error["message"] as? String)
            XCTAssertTrue(
                message.contains(maliciousVersion),
                "Expected the raw header echoed back safely, got \(message)"
            )
        }
    }

    func testOriginMiddlewareRejectsBadOriginAndHost() async throws {
        let middleware = OriginValidationMiddleware<BasicRequestContext>()
        let context = BasicRequestContext(
            source: ApplicationRequestContextSource(
                channel: EmbeddedChannel(),
                logger: Logger(label: #function)
            )
        )

        let blockedOriginRequest = Request(
            head: .init(
                method: .post,
                scheme: "http",
                authority: "localhost",
                path: "/",
                headerFields: [HTTPField.Name("Origin")!: "https://malicious.example"]
            ),
            body: .init(buffer: ByteBuffer())
        )
        let blockedOriginResponse = try await middleware.handle(
            blockedOriginRequest,
            context: context
        ) { _, _ in
            XCTFail("Blocked origin should not reach next middleware")
            return Response(status: .ok)
        }
        XCTAssertEqual(blockedOriginResponse.head.status, HTTPResponse.Status.forbidden)

        let blockedHostRequest = Request(
            head: .init(
                method: .post,
                scheme: "http",
                authority: "example.com",
                path: "/",
                headerFields: [:]
            ),
            body: .init(buffer: ByteBuffer())
        )
        let blockedHostResponse = try await middleware.handle(
            blockedHostRequest,
            context: context
        ) { _, _ in
            XCTFail("Blocked host should not reach next middleware")
            return Response(status: .ok)
        }
        XCTAssertEqual(blockedHostResponse.head.status, HTTPResponse.Status.forbidden)

        let allowedRequest = Request(
            head: .init(
                method: .post,
                scheme: "http",
                authority: "localhost",
                path: "/",
                headerFields: [HTTPField.Name("Origin")!: "http://localhost:3000"]
            ),
            body: .init(buffer: ByteBuffer())
        )
        let allowedResponse = try await middleware.handle(
            allowedRequest,
            context: context
        ) { _, _ in
            Response(status: .ok)
        }
        XCTAssertEqual(allowedResponse.head.status, HTTPResponse.Status.ok)
    }

    func testSSEGetRejectsMissingEventStreamAccept() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            requestTimeout: .seconds(5),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.get,
                headers: [.accept: "application/json"],
                body: nil
            )

            let body = try decodeJSONString(from: response.body)
            XCTAssertEqual(response.head.status, .notAcceptable, body)
            XCTAssertTrue(body.contains("Invalid Accept header"), body)
        }
    }

    func testSSEGetRejectsMissingSessionHeader() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            requestTimeout: .seconds(5),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.get,
                headers: [.accept: "text/event-stream"],
                body: nil
            )

            let body = try decodeJSONString(from: response.body)
            XCTAssertEqual(response.head.status, .badRequest, body)
            XCTAssertTrue(body.contains("Missing Mcp-Session-Id header"), body)
        }
    }

    func testSSEGetRejectsUnknownSession() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            requestTimeout: .seconds(5),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            var headers: HTTPFields = [.accept: "text/event-stream"]
            headers[.mcpSessionId] = "not-a-real-session"

            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.get,
                headers: headers,
                body: nil
            )

            let body = try decodeJSONString(from: response.body)
            XCTAssertEqual(response.head.status, .notFound, body)
            XCTAssertTrue(body.contains("Invalid or expired session"), body)
        }
    }

    // The GET here calls `handleGet` directly rather than going through
    // `client.executeRequest`, unlike every other test in this file. That is
    // deliberate. Do not "fix" it back, it will hang the whole suite.
    //
    // `handleGet` answers with a long-lived streaming body that pumps the SSE
    // channel (keep-alives included) until the connection is unregistered, and
    // `RouterTestFramework` runs `try await response.body.write(responseWriter)`
    // to completion *before* it constructs the `TestResponse`
    // (RouterTestFramework.swift:122). So a body that never ends means
    // `executeRequest` never returns, and the head asserted on below is
    // unreachable through the client.
    //
    // The head, by contrast, is fully populated the moment `handleGet` returns,
    // and nothing obliges us to invoke the body writer. Calling the handler
    // directly gets the head without ever starting the stream. `handleGet`
    // never reads `context`, so any context instance satisfies the generic.
    func testSSEGetOpensStreamForLiveSession() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            requestTimeout: .seconds(5),
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let sessionId = try await initializeSession(using: client)

            var headers: HTTPFields = [.accept: "text/event-stream"]
            headers[.mcpSessionId] = sessionId

            let request = Request(
                head: .init(
                    method: HTTPRequest.Method.get,
                    scheme: "http",
                    authority: "localhost",
                    path: "/",
                    headerFields: headers
                ),
                body: .init(buffer: ByteBuffer())
            )
            let context = BasicRequestContext(
                source: ApplicationRequestContextSource(
                    channel: EmbeddedChannel(),
                    logger: Logger(label: #function)
                )
            )

            let response = try await transport.handleGet(request: request, context: context)

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
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            requestTimeout: .seconds(5),
            maxSessions: 1,
            cleanupInterval: .milliseconds(20)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let firstResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(),
                body: byteBuffer(for: initializePayload(id: 1))
            )
            let firstBody = try decodeJSONString(from: firstResponse.body)
            XCTAssertEqual(firstResponse.head.status, .ok, firstBody)
            let firstSessionId = try XCTUnwrap(firstResponse.head.headerFields[.mcpSessionId])
            XCTAssertFalse(firstSessionId.isEmpty)

            let secondResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(),
                body: byteBuffer(for: initializePayload(id: 2))
            )
            let secondBody = try decodeJSONString(from: secondResponse.body)
            XCTAssertEqual(secondResponse.head.status, .serviceUnavailable, secondBody)
            XCTAssertTrue(secondBody.contains("Session capacity reached"), secondBody)
            XCTAssertTrue(secondBody.contains("Reuse an existing session"), secondBody)
            XCTAssertTrue(secondBody.contains("DELETE"), secondBody)
            XCTAssertTrue(secondBody.contains("Mcp-Session-Id"), secondBody)
            XCTAssertTrue(secondBody.contains("idle sessions expire"), secondBody)

            let deleteResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.delete,
                headers: jsonHeaders(sessionId: firstSessionId),
                body: ByteBuffer()
            )
            XCTAssertEqual(deleteResponse.head.status, .noContent)

            let recoveredResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(),
                body: byteBuffer(for: initializePayload(id: 3))
            )
            let recoveredBody = try decodeJSONString(from: recoveredResponse.body)
            XCTAssertEqual(recoveredResponse.head.status, .ok, recoveredBody)
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

private func initializePayload(id: Int, protocolVersion: String = "2025-03-26") -> String {
    """
    {"jsonrpc":"2.0","id":\(id),"method":"initialize","params":{"protocolVersion":"\(protocolVersion)","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}}}
    """
}

private func toolsListPayload(id: Int) -> String {
    """
    {"jsonrpc":"2.0","id":\(id),"method":"tools/list","params":{}}
    """
}

private func slowMethodPayload(id: String) -> String {
    """
    {"jsonrpc":"2.0","id":"\(id)","method":"\(TestSlowMethod.name)","params":{"token":"\(id)"}}
    """
}

private func jsonHeaders(sessionId: String? = nil, protocolVersion: String? = nil) -> HTTPFields {
    var headers: HTTPFields = [
        .contentType: "application/json",
        .accept: "application/json, text/event-stream",
    ]
    if let sessionId {
        headers[.mcpSessionId] = sessionId
    }
    if let protocolVersion {
        headers[.mcpProtocolVersion] = protocolVersion
    }
    return headers
}

private func byteBuffer(for string: String) -> ByteBuffer {
    ByteBuffer(string: string)
}

private func decodeJSONString(from buffer: ByteBuffer) throws -> String {
    var body = buffer
    return try XCTUnwrap(body.readString(length: body.readableBytes))
}

private func decodeJSON(from buffer: ByteBuffer) throws -> [String: Any] {
    let body = try decodeJSONString(from: buffer)
    let data = Data(body.utf8)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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

    for icon in icons {
        let src = icon["src"] as? String
        XCTAssertEqual(icon["mimeType"] as? String, "image/png", file: file, line: line)
        XCTAssertTrue(src?.hasPrefix("data:image/png;base64,") == true, "\(context) icon should use a PNG data URI", file: file, line: line)
        assertPNGDataURI(src, context: context, file: file, line: line)
    }
}

private func assertPNGDataURI(_ src: String?, context: String, file: StaticString = #filePath, line: UInt = #line) {
    let prefix = "data:image/png;base64,"
    guard let src, src.hasPrefix(prefix) else {
        return XCTFail("\(context) icon is not a PNG data URI", file: file, line: line)
    }
    let encoded = String(src.dropFirst(prefix.count))
    guard let data = Data(base64Encoded: encoded) else {
        return XCTFail("\(context) icon base64 is invalid", file: file, line: line)
    }
    XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], file: file, line: line)
}

private func slowMethodSource(from buffer: ByteBuffer) throws -> String {
    let json = try decodeJSON(from: buffer)
    let result = try XCTUnwrap(json["result"] as? [String: Any])
    return try XCTUnwrap(result["source"] as? String)
}

private func initializeSession(
    using client: any TestClientProtocol,
    protocolVersion: String = "2025-03-26"
) async throws -> String {
    let response = try await client.executeRequest(
        uri: "/",
        method: HTTPRequest.Method.post,
        headers: jsonHeaders(),
        body: byteBuffer(for: initializePayload(id: Int.random(in: 1...10_000), protocolVersion: protocolVersion))
    )
    if response.head.status != .ok {
        let body = try decodeJSONString(from: response.body)
        XCTFail("Initialize failed: \(body)")
    }
    return try XCTUnwrap(response.head.headerFields[.mcpSessionId])
}
