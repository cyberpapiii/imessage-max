import XCTest
import Darwin
@testable import iMessageMax

final class HTTPTransportLiveSocketTests: XCTestCase {

    func testIdleChannelIsClosedByServer() async throws {
        try await withLiveTransport(channelIdleTimeout: .milliseconds(300)) { _, port in
            let fd = try connectLoopback(port: port)
            defer { close(fd) }
            setRecvTimeout(fd, seconds: 2)

            let request = "POST / HTTP/1.1\r\nHost: x\r\nAuthorization: \(testAuthorization)\r\nContent-Length: 10\r\n\r\n{"
            try writeAll(fd, request)

            var sawEOF = false
            var received = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 256)
            while true {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n == 0 {
                    sawEOF = true
                    break
                }
                if n < 0 { break }
                received.append(contentsOf: buffer.prefix(n))
                if received.count > 4096 { break }
            }
            XCTAssertTrue(
                sawEOF,
                "idle channel should close with EOF, got \(received.count) bytes: \(String(decoding: received, as: UTF8.self))"
            )
        }
    }

    func testSSEGetSurvivesChannelIdleTimeout() async throws {
        try await withLiveTransport(channelIdleTimeout: .milliseconds(300)) { _, port in
            let initFd = try connectLoopback(port: port)
            defer { close(initFd) }
            setRecvTimeout(initFd, seconds: 2)

            let body = """
                {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}}}
                """
            let post = """
                POST / HTTP/1.1\r\n\
                Host: 127.0.0.1\r\n\
                Authorization: \(testAuthorization)\r\n\
                Content-Type: application/json\r\n\
                Accept: application/json, text/event-stream\r\n\
                Content-Length: \(body.utf8.count)\r\n\
                \r\n\
                \(body)
                """
            try writeAll(initFd, post)
            let response = try readUntilDoubleCRLF(initFd)
            let sessionId = try XCTUnwrap(
                sessionId(from: response),
                "initialize response missing Mcp-Session-Id: \(response)"
            )

            let getFd = try connectLoopback(port: port)
            defer { close(getFd) }
            setRecvTimeout(getFd, seconds: 2)
            let get = """
                GET / HTTP/1.1\r\n\
                Host: 127.0.0.1\r\n\
                Authorization: \(testAuthorization)\r\n\
                Accept: text/event-stream\r\n\
                Mcp-Session-Id: \(sessionId)\r\n\
                \r\n
                """
            try writeAll(getFd, get)
            await AsyncTimeout.sleep(.seconds(1))

            var one: [UInt8] = [0]
            let n = recv(getFd, &one, 1, MSG_PEEK)
            XCTAssertNotEqual(n, 0, "SSE GET hit EOF after 1s idle")
        }
    }

    func testNewMessagesNotificationReachesOpenSSEGet() async throws {
        try await withLiveTransport(channelIdleTimeout: .seconds(5)) { transport, port in
            let sessionA = try initializeSession(port: port)
            let sessionB = try initializeSession(port: port)

            let getFd = try connectLoopback(port: port)
            defer { close(getFd) }
            setRecvTimeout(getFd, seconds: 2)
            let get = """
                GET / HTTP/1.1\r\n\
                Host: 127.0.0.1\r\n\
                Authorization: \(testAuthorization)\r\n\
                Accept: text/event-stream\r\n\
                Mcp-Session-Id: \(sessionA)\r\n\
                \r\n
                """
            try writeAll(getFd, get)
            _ = try readUntilDoubleCRLF(getFd)

            let delivered = await transport.notifyNewMessages(maxRowid: 4242)
            XCTAssertEqual(delivered, 2)

            var received = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 1024)
            let deadline = ContinuousClock.now + .seconds(2)
            var text = ""
            while ContinuousClock.now < deadline {
                let n = recv(getFd, &buffer, buffer.count, 0)
                if n > 0 {
                    received.append(contentsOf: buffer.prefix(n))
                    text = String(decoding: received, as: UTF8.self)
                    if text.contains("notifications/imessage/new_messages") { break }
                }
            }
            XCTAssertTrue(text.contains("notifications/imessage/new_messages"), "SSE GET: \(text)")
            XCTAssertTrue(text.contains("\"max_rowid\":4242"), "SSE GET: \(text)")
            XCTAssertTrue(text.contains("event: message"), "SSE GET: \(text)")

            _ = sessionB
        }
    }

    func testDeletingSessionEndsItsSSEResponse() async throws {
        try await withLiveTransport(channelIdleTimeout: .seconds(5)) { _, port in
            let session = try initializeSession(port: port)
            let getFd = try connectLoopback(port: port)
            defer { close(getFd) }
            setRecvTimeout(getFd, seconds: 2)
            try writeAll(getFd, """
                GET / HTTP/1.1\r\n\
                Host: 127.0.0.1\r\n\
                Authorization: \(testAuthorization)\r\n\
                Accept: text/event-stream\r\n\
                Mcp-Session-Id: \(session)\r\n\
                \r\n
                """)
            _ = try readUntilDoubleCRLF(getFd)

            let deleteFd = try connectLoopback(port: port)
            defer { close(deleteFd) }
            setRecvTimeout(deleteFd, seconds: 2)
            try writeAll(deleteFd, """
                DELETE / HTTP/1.1\r\n\
                Host: 127.0.0.1\r\n\
                Authorization: \(testAuthorization)\r\n\
                Mcp-Session-Id: \(session)\r\n\
                \r\n
                """)
            _ = try readUntilDoubleCRLF(deleteFd)

            var received = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 256)
            while !String(decoding: received, as: UTF8.self).contains("0\r\n\r\n") {
                let n = recv(getFd, &buffer, buffer.count, 0)
                if n <= 0 { break }
                received.append(contentsOf: buffer.prefix(n))
            }
            XCTAssertTrue(
                String(decoding: received, as: UTF8.self).contains("0\r\n\r\n"),
                "SSE response never ended: \(String(decoding: received, as: UTF8.self))"
            )
        }
    }

    func testGracefulShutdownClosesOpenSSEStreams() async throws {
        try await withLiveTransport(channelIdleTimeout: .seconds(5)) { transport, port in
            let session = try initializeSession(port: port)
            let getFd = try connectLoopback(port: port)
            defer { close(getFd) }
            setRecvTimeout(getFd, seconds: 5)
            try writeAll(getFd, """
                GET / HTTP/1.1\r\n\
                Host: 127.0.0.1\r\n\
                Authorization: \(testAuthorization)\r\n\
                Accept: text/event-stream\r\n\
                Mcp-Session-Id: \(session)\r\n\
                \r\n
                """)
            _ = try readUntilDoubleCRLF(getFd)

            let start = ContinuousClock.now
            await transport.shutdown()
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(3), "graceful shutdown waited on the open SSE stream")
        }
    }

    func testOpenSSEStreamKeepsItsSessionAlive() async throws {
        try await withLiveTransport(
            channelIdleTimeout: .seconds(5),
            sessionTimeout: 0.5,
            sseKeepAliveInterval: .milliseconds(100)
        ) { _, port in
            let session = try initializeSession(port: port)
            let getFd = try connectLoopback(port: port)
            defer { close(getFd) }
            setRecvTimeout(getFd, seconds: 1)
            try writeAll(getFd, """
                GET / HTTP/1.1\r\n\
                Host: 127.0.0.1\r\n\
                Authorization: \(testAuthorization)\r\n\
                Accept: text/event-stream\r\n\
                Mcp-Session-Id: \(session)\r\n\
                \r\n
                """)
            _ = try readUntilDoubleCRLF(getFd)

            var received = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 256)
            let deadline = ContinuousClock.now + .milliseconds(1500)
            while ContinuousClock.now < deadline {
                let n = recv(getFd, &buffer, buffer.count, 0)
                if n <= 0 { break }
                received.append(contentsOf: buffer.prefix(n))
                if String(decoding: received, as: UTF8.self).contains("0\r\n\r\n") { break }
            }
            let text = String(decoding: received, as: UTF8.self)
            XCTAssertFalse(text.contains("0\r\n\r\n"), "session expired under an open SSE stream")
            XCTAssertGreaterThanOrEqual(ContinuousClock.now, deadline, "SSE stream ended early: \(text)")
        }
    }

    private func withLiveTransport(
        channelIdleTimeout: Duration,
        sessionTimeout: TimeInterval = 3600,
        sseKeepAliveInterval: Duration = .seconds(30),
        body: (HTTPTransport, Int) async throws -> Void
    ) async throws {
        let port = try freeLoopbackPort()
        var configuration = HTTPTransport.Configuration.test
        configuration.channelIdleTimeout = channelIdleTimeout
        configuration.sessionTimeout = sessionTimeout
        configuration.sseKeepAliveInterval = sseKeepAliveInterval
        let transport = makeTestTransport(port: port, configuration: configuration)
        try await transport.connect(gracefulShutdownSignals: [])
        do {
            try await waitUntilListening(port: port)
            try await body(transport, port)
        } catch {
            await transport.shutdown()
            throw error
        }
        await transport.shutdown()
    }
}

private func waitUntilListening(port: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while true {
        do {
            close(try connectLoopback(port: port))
            return
        } catch where ContinuousClock.now < deadline {
            await AsyncTimeout.sleep(.milliseconds(10))
        }
    }
}
