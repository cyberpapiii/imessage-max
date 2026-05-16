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
            resolver: ContactResolver(),
            requestTimeout: .seconds(5)
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
                if tool["name"] as? String != "get_attachment" {
                    XCTAssertNotNil(tool["outputSchema"], "\(tool["name"] ?? "unknown") missing outputSchema")
                }
            }
        }
    }

    func testLatestProtocolRequiresVersionHeaderAfterInitialize() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(),
            requestTimeout: .seconds(5)
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
            requestTimeout: .seconds(5)
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
            resolver: ContactResolver(),
            requestTimeout: .seconds(5)
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

    func testInvalidSessionReturnsNotFound() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(),
            requestTimeout: .seconds(5)
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
            requestTimeout: .seconds(2)
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
            requestTimeout: .milliseconds(20)
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

            try await Task.sleep(for: .milliseconds(80))

            let secondResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(sessionId: sessionId),
                body: byteBuffer(for: toolsListPayload(id: 3))
            )
            XCTAssertEqual(secondResponse.head.status, .ok)
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
