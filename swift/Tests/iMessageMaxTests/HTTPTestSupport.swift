import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MCP
import NIOCore
import XCTest
@testable import iMessageMax

/// The token every test transport requires. Tests that check rejection
/// build their own headers.
let testAccessToken = AccessToken.generate()
var testAuthorization: String { "Bearer \(testAccessToken.encoded)" }

func initializeBody(id: Int = 1, protocolVersion: String = "2025-03-26") -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{"protocolVersion":"\#(protocolVersion)","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}}}"#
}

func modernBody(
    id: Int? = 1,
    method: String,
    params: String = "",
    version: String = "2026-07-28"
) -> String {
    let idMember = id.map { #""id":\#($0),"# } ?? ""
    let extra = params.isEmpty ? "" : "\(params),"
    return #"{"jsonrpc":"2.0",\#(idMember)"method":"\#(method)","params":{\#(extra)"_meta":{"io.modelcontextprotocol/protocolVersion":"\#(version)","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"tests","version":"1.0"}}}}"#
}

func fakeTool(
    named name: String,
    handler: @escaping @Sendable ([String: Value]?) async throws -> [Tool.Content] = { _ in [.plainText("ok")] }
) -> ToolDefinition {
    ToolDefinition(name: name, description: "test tool", inputSchema: InputSchema.object(properties: [:]), handler: handler)
}

func waitForCancelTool(started: AsyncStream<Void>.Continuation) -> ToolDefinition {
    fakeTool(named: "wait_for_cancel") { _ in
        started.yield()
        for _ in 0..<500 {
            try Task.checkCancellation()
            await AsyncTimeout.sleep(.milliseconds(20))
        }
        return [.plainText(#"{"finished":true}"#)]
    }
}

func makeTestTransport(
    catalog: ToolCatalog = makeTestCatalog(),
    port: Int = 0,
    configuration: HTTPTransport.Configuration = .test
) -> HTTPTransport {
    HTTPTransport(
        host: "127.0.0.1",
        port: port,
        accessToken: testAccessToken,
        catalog: catalog,
        setupPermissions: makeTestSetupPermissions(),
        configuration: configuration
    )
}

extension HTTPTransport.Configuration {
    static var test: Self { .init(requestTimeout: .seconds(5), cleanupInterval: .milliseconds(20)) }
}

func jsonHeaders(sessionId: String? = nil, protocolVersion: String? = nil) -> HTTPFields {
    var headers: HTTPFields = [
        .contentType: "application/json",
        .accept: "application/json, text/event-stream",
        .authorization: testAuthorization,
    ]
    headers[.mcpSessionId] = sessionId
    headers[.mcpProtocolVersion] = protocolVersion
    return headers
}

func modernHeaders(method: String, name: String? = nil, version: String = "2026-07-28") -> HTTPFields {
    var headers = jsonHeaders(protocolVersion: version)
    headers[.mcpMethod] = method
    headers[.mcpName] = name
    return headers
}

extension TestClientProtocol {
    func post(_ body: String, headers: HTTPFields = jsonHeaders()) async throws -> TestResponse {
        try await executeRequest(uri: "/", method: .post, headers: headers, body: ByteBuffer(string: body))
    }

    func initializeSession(
        protocolVersion: String = "2025-03-26",
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> String {
        let response = try await post(initializeBody(id: Int.random(in: 1...10_000), protocolVersion: protocolVersion))
        XCTAssertEqual(response.head.status, .ok, String(buffer: response.body), file: file, line: line)
        return try XCTUnwrap(response.head.headerFields[.mcpSessionId], file: file, line: line)
    }
}
