import XCTest
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
@testable import iMessageMax

final class BearerAuthTests: XCTestCase {
    private struct Probe: Sendable {
        let method: HTTPRequest.Method
        let uri: String
        let body: String?
    }

    private static let probes = [
        Probe(method: .post, uri: "/", body: modernBody(method: "server/discover")),
        Probe(method: .post, uri: "/", body: initializeBody()),
        Probe(method: .get, uri: "/", body: nil),
        Probe(method: .delete, uri: "/", body: nil),
        Probe(method: .post, uri: "/setup/permissions", body: #"{"permission":"automation"}"#),
        Probe(method: .get, uri: "/.well-known/oauth-protected-resource", body: nil),
        Probe(method: .put, uri: "/", body: nil),
    ]

    private static var wrongTokens: [(String, String?)] {
        let real = testAccessToken.encoded
        let flipped = String(real.dropLast()) + (real.last == "A" ? "B" : "A")
        return [
            ("missing", nil),
            ("wrong, same length", "Bearer \(flipped)"),
            ("wrong, shorter", "Bearer \(real.dropLast())"),
            ("wrong, longer", "Bearer \(real)x"),
            ("empty", "Bearer "),
            ("another scheme", "Basic \(real)"),
            ("no scheme", real),
            ("two headers", "Bearer \(real), Bearer \(real)"),
        ]
    }

    func testEveryRouteRejectsMissingOrWrongToken() async throws {
        let app = await makeTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            for probe in Self.probes {
                for (label, authorization) in Self.wrongTokens {
                    let response = try await Self.send(probe, authorization: authorization, client: client)
                    let context = "\(probe.method) \(probe.uri) \(label)"
                    XCTAssertEqual(response.head.status, .unauthorized, context)
                    try Self.assertUnauthorizedBody(response, context: context)
                }
            }
        }
    }

    func testUnauthorizedReplyNamesTheFixAndTheScheme() async throws {
        let app = await makeTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            let missing = try await Self.send(Self.probes[0], authorization: nil, client: client)
            XCTAssertEqual(missing.head.headerFields[.wwwAuthenticate], #"Bearer realm="imessage-max""#)
            XCTAssertEqual(missing.head.headerFields[.contentType], "application/json")

            let wrong = try await Self.send(Self.probes[0], authorization: "Bearer nope", client: client)
            XCTAssertEqual(
                wrong.head.headerFields[.wwwAuthenticate], #"Bearer realm="imessage-max", error="invalid_token""#)

            let envelope = try decodeJSON(from: missing.body)
            XCTAssertEqual(envelope["jsonrpc"] as? String, "2.0")
            XCTAssertTrue(envelope["id"] is NSNull)
            let error = try XCTUnwrap(envelope["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, JSONRPCErrorCode.invalidRequest.rawValue)
            XCTAssertEqual(
                error["message"] as? String,
                "Unauthorized. Open iMessage Max and choose Connect, or copy the token from the app.")
        }
    }

    func testModernLaneAnswersWithToken() async throws {
        let app = await makeTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.post(
                modernBody(method: "server/discover"), headers: modernHeaders(method: "server/discover"))
            XCTAssertEqual(response.head.status, .ok, String(buffer: response.body))
            XCTAssertNotNil(try decodeJSON(from: response.body)["result"])
        }
    }

    func testLegacySessionNeedsTokenOnEveryRequest() async throws {
        let app = await makeTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession()
            let toolsList = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#

            let listed = try await client.post(toolsList, headers: jsonHeaders(sessionId: sessionId))
            XCTAssertEqual(listed.head.status, .ok, String(buffer: listed.body))
            XCTAssertNotNil(try decodeJSON(from: listed.body)["result"])

            var stolenSession = jsonHeaders(sessionId: sessionId)
            stolenSession[.authorization] = nil
            let refused = try await client.post(toolsList, headers: stolenSession)
            XCTAssertEqual(refused.head.status, .unauthorized)

            var deleteHeaders = stolenSession
            deleteHeaders[.mcpProtocolVersion] = "2025-03-26"
            let deleteRefused = try await client.executeRequest(
                uri: "/", method: .delete, headers: deleteHeaders, body: nil)
            XCTAssertEqual(deleteRefused.head.status, .unauthorized)

            let stillAlive = try await client.post(toolsList, headers: jsonHeaders(sessionId: sessionId))
            XCTAssertEqual(stillAlive.head.status, .ok, "a refused DELETE must not end the session")
        }
    }

    func testSetupRouteReachesHandlerOnlyWithToken() async throws {
        let app = await makeTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            var headers: HTTPFields = [
                .contentType: "application/json",
                HTTPField.Name("X-iMessage-Max-Setup")!: "permission-request-v1",
            ]
            let body = ByteBuffer(string: #"{"permission":"automation"}"#)
            let refused = try await client.executeRequest(
                uri: "/setup/permissions", method: .post, headers: headers, body: body)
            XCTAssertEqual(refused.head.status, .unauthorized)

            headers[.authorization] = testAuthorization
            let accepted = try await client.executeRequest(
                uri: "/setup/permissions", method: .post, headers: headers, body: body)
            XCTAssertEqual(accepted.head.status, .ok, String(buffer: accepted.body))
        }
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertTrue(testAccessToken.authorizes("bearer \(testAccessToken.encoded)"))
        XCTAssertTrue(testAccessToken.authorizes("BEARER \(testAccessToken.encoded)"))
        XCTAssertFalse(testAccessToken.authorizes("Bearer  \(testAccessToken.encoded)"))
        XCTAssertFalse(testAccessToken.authorizes("Bearer\0\(testAccessToken.encoded)"))
    }

    func testRejectionLogsOneLineWithoutAnyToken() async throws {
        let presented = "Bearer \(AccessToken.generate().encoded)"
        let capture = Log.Capture()
        let app = await makeTestTransport().application()
        try await Log.$capture.withValue(capture) {
            try await app.test(TestingSetup.router) { client in
                var headers = modernHeaders(method: "tools/call", name: "diagnose")
                headers[.authorization] = presented
                _ = try await client.post(
                    modernBody(method: "tools/call", params: #""name":"diagnose","arguments":{}"#), headers: headers)
                headers[.authorization] = nil
                headers[.mcpMethod] = "tools/list\nINFO Forged 42"
                _ = try await client.post(modernBody(method: "tools/list"), headers: headers)
                _ = try await client.post(modernBody(method: "server/discover"), headers: modernHeaders(method: "server/discover"))
            }
        }
        let rejections = capture.lines.filter { $0.hasPrefix("auth=rejected") }
        XCTAssertEqual(rejections.count, 2, "\(capture.lines)")
        XCTAssertEqual(rejections.first, "auth=rejected reason=invalid_token http=POST path=/ method=tools/call")
        XCTAssertEqual(rejections.last, "auth=rejected reason=missing_token http=POST path=/ method=tools/listorged")
        for line in capture.lines {
            XCTAssertFalse(line.contains(testAccessToken.encoded), line)
            XCTAssertFalse(line.contains(presented.dropFirst(7)), line)
            XCTAssertFalse(line.contains("\n"), line)
        }
    }

    private static func send(_ probe: Probe, authorization: String?, client: some TestClientProtocol) async throws -> TestResponse {
        var headers = jsonHeaders()
        headers[.authorization] = authorization
        headers[HTTPField.Name("X-iMessage-Max-Setup")!] = "permission-request-v1"
        return try await client.executeRequest(
            uri: probe.uri, method: probe.method, headers: headers, body: probe.body.map { ByteBuffer(string: $0) })
    }

    private static func assertUnauthorizedBody(_ response: TestResponse, context: String) throws {
        let error = try XCTUnwrap(try decodeJSON(from: response.body)["error"] as? [String: Any], context)
        XCTAssertTrue((error["message"] as? String)?.contains(BearerAuthMiddleware<BasicRequestContext>.fix) == true, context)
    }
}
