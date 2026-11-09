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

    /// connect() returns only once the bind has an outcome, and a taken port
    /// is an outcome, not an error: the transport binds once it frees.
    func testConnectReportsATakenPortAndBindsOnceItFrees() async throws {
        let holder = try HeldPort()
        var configuration = HTTPTransport.Configuration.test
        configuration.bindRetry = BindRetry(initial: .milliseconds(20), maximum: .milliseconds(100))
        let transport = makeTestTransport(port: holder.port, configuration: configuration)
        let capture = Log.Capture()
        let outcome = try await Log.$capture.withValue(capture) {
            try await transport.connect(gracefulShutdownSignals: [])
        }
        XCTAssertEqual(outcome, .portInUse)
        XCTAssertEqual(transport.listenerState.current, .portInUse)
        XCTAssertEqual(transport.listenerState.diagnosis(port: holder.port).state, .portInUse)
        XCTAssertEqual(capture.lines.filter { $0.contains("is in use by another process") }.count, 1, "\(capture.lines)")

        holder.release()
        let deadline = ContinuousClock.now + .seconds(5)
        while !transport.listenerState.isListening, ContinuousClock.now < deadline {
            await AsyncTimeout.sleep(.milliseconds(10))
        }
        XCTAssertTrue(transport.listenerState.isListening)
        _ = try initializeSession(port: holder.port)
        await transport.shutdown()
    }

    func testConnectReturnsListeningOnceTheServerAcceptsConnections() async throws {
        let port = try freeLoopbackPort()
        let transport = makeTestTransport(port: port)
        let outcome = try await transport.connect(gracefulShutdownSignals: [])
        XCTAssertEqual(outcome, .listening)
        close(try connectLoopback(port: port))
        await transport.shutdown()
    }

    func testShutdownWhileWaitingForATakenPortEnds() async throws {
        let holder = try HeldPort()
        defer { holder.release() }
        let transport = makeTestTransport(port: holder.port)
        let outcome = try await transport.connect(gracefulShutdownSignals: [])
        XCTAssertEqual(outcome, .portInUse)
        let start = ContinuousClock.now
        await transport.shutdown()
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "shutdown waited out the bind retry")
    }

    func testBindRetryDoublesUpToTheCap() {
        let retry = BindRetry(initial: .seconds(1), maximum: .seconds(30))
        XCTAssertEqual((0..<8).map { retry.delay(after: $0) }, [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
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

/// A listener on a free loopback port, as another process would hold it.
final class HeldPort {
    let port: Int
    private var fd: Int32

    init() throws {
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SocketError(errno) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let descriptor = fd
        let rc = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length) == 0 && listen(descriptor, 4) == 0 ? getsockname(descriptor, $0, &length) : -1
            }
        }
        guard rc == 0 else {
            close(fd)
            throw SocketError(errno)
        }
        port = Int(in_port_t(bigEndian: addr.sin_port))
    }

    func release() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    deinit { release() }
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
