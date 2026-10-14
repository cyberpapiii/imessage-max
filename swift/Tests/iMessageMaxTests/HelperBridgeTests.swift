// swift/Tests/iMessageMaxTests/HelperBridgeTests.swift
import XCTest
@testable import iMessageMax

/// In-memory transport: returns a canned response line for each request, or a
/// thrown error. Records requests for assertions.
final class StubHelperTransport: HelperTransport, @unchecked Sendable {
    private(set) var sentLines: [String] = []
    var connected = true
    /// Given the decoded request, produce the raw response line (no newline) or throw.
    var responder: (HelperRequest) throws -> String = { _ in "" }

    func roundTrip(_ request: Data, timeout: TimeInterval) async throws -> Data {
        guard connected else { throw HelperError.notConnected }
        let line = String(decoding: request, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        sentLines.append(line)
        let decoded = try JSONDecoder().decode(HelperRequest.self, from: Data(line.utf8))
        return Data(try responder(decoded).utf8)
    }
    func isConnected() async -> Bool { connected }
}

final class HelperBridgeTests: XCTestCase {
    private func bridge(_ t: StubHelperTransport) -> HelperBridge {
        HelperBridge(transport: t, timeout: 1, idFactory: { "fixed-id" })
    }

    func testCreateGroupChatReturnsGuid() async {
        let t = StubHelperTransport()
        t.responder = { req in
            XCTAssertEqual(req.cmd, .createChat)
            XCTAssertEqual(req.addresses, ["+1", "+2"])
            return #"{"v":1,"id":"fixed-id","ok":true,"chat_guid":"iMessage;+;g"}"#
        }
        let result = await bridge(t).createGroupChat(addresses: ["+1", "+2"])
        XCTAssertEqual(result, .success("iMessage;+;g"))
    }

    func testRemoteErrorSurfacesAsHelperError() async {
        let t = StubHelperTransport()
        t.responder = { _ in
            #"{"v":1,"id":"fixed-id","ok":false,"error":{"code":"handle_not_found","message":"no such handle"}}"#
        }
        let result = await bridge(t).createGroupChat(addresses: ["+1", "+2"])
        XCTAssertEqual(result, .failure(.remote(code: "handle_not_found", message: "no such handle")))
    }

    func testProtocolVersionMismatchRejected() async {
        let t = StubHelperTransport()
        t.responder = { _ in #"{"v":2,"id":"fixed-id","ok":true}"# }
        let result = await bridge(t).sendText(chatGuid: "g", body: "hi")
        switch result {
        case .failure(.protocolMismatch(expected: 1, got: 2)):
            break
        default:
            XCTFail("Expected .failure(.protocolMismatch(expected: 1, got: 2)), got \(result)")
        }
    }

    func testIdMismatchRejected() async {
        let t = StubHelperTransport()
        t.responder = { _ in #"{"v":1,"id":"WRONG","ok":true}"# }
        let result = await bridge(t).sendText(chatGuid: "g", body: "hi")
        switch result {
        case .failure(.idMismatch(expected: "fixed-id", got: "WRONG")):
            break
        default:
            XCTFail("Expected .failure(.idMismatch(expected: \"fixed-id\", got: \"WRONG\")), got \(result)")
        }
    }

    func testProbeTrueOnOkPong() async {
        let t = StubHelperTransport()
        t.responder = { req in
            XCTAssertEqual(req.cmd, .ping)
            return #"{"v":1,"id":"fixed-id","ok":true}"#
        }
        let ok = await bridge(t).probe()
        XCTAssertTrue(ok)
    }

    func testProbeFalseWhenDisconnected() async {
        let t = StubHelperTransport()
        t.connected = false
        let ok = await bridge(t).probe()
        XCTAssertFalse(ok)
    }
}

extension HelperBridgeTests {
    func testUnixSocketTransportRoundTripsOverSocketpair() async throws {
        var fds: [Int32] = [0, 0]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        try XCTSkipUnless(rc == 0, "socketpair unavailable")
        let clientFD = fds[0]
        let serverFD = fds[1]

        // Fake server: read one line, reply with a pong echoing the request id.
        let server = Thread {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(serverFD, &buf, buf.count)
            let line = String(decoding: buf[0..<max(0, n)], as: UTF8.self)
            let req = try! JSONDecoder().decode(HelperRequest.self,
                                                from: Data(line.trimmingCharacters(in: .newlines).utf8))
            let reply = #"{"v":1,"id":"\#(req.id)","ok":true}\#("\n")"#
            _ = Data(reply.utf8).withUnsafeBytes { write(serverFD, $0.baseAddress, $0.count) }
            close(serverFD)
        }
        server.start()

        let transport = UnixSocketTransport(connectedFD: clientFD)
        let bridge = HelperBridge(transport: transport, timeout: 2, idFactory: { "pp" })
        let ok = await bridge.probe()
        XCTAssertTrue(ok)
    }
}
