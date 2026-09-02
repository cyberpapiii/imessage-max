import XCTest
import Darwin
@testable import iMessageMax

final class HTTPTransportLiveSocketTests: XCTestCase {

    func testIdleChannelIsClosedByServer() async throws {
        try await withLiveTransport(channelIdleTimeout: .milliseconds(300)) { _, port in
            let fd = try connectLoopback(port: port)
            defer { close(fd) }
            setRecvTimeout(fd, seconds: 2)

            let request = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n{"
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

    /// SSE keep-alive interval is not injectable through HTTPTransport, so
    /// this only asserts the GET stays open across three 300 ms idle periods.
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
                Accept: text/event-stream\r\n\
                Mcp-Session-Id: \(sessionId)\r\n\
                \r\n
                """
            try writeAll(getFd, get)
            await AsyncTimeout.sleep(.seconds(1))

            var peek: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            let rc = getsockopt(getFd, SOL_SOCKET, SO_ERROR, &peek, &len)
            XCTAssertEqual(rc, 0)
            XCTAssertEqual(peek, 0, "SSE GET closed by idle timeout")

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
                Accept: text/event-stream\r\n\
                Mcp-Session-Id: \(sessionA)\r\n\
                \r\n
                """
            try writeAll(getFd, get)
            await AsyncTimeout.sleep(.milliseconds(200))
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

    private func withLiveTransport(
        channelIdleTimeout: Duration,
        body: (HTTPTransport, Int) async throws -> Void
    ) async throws {
        var lastError: Error?
        for _ in 0..<2 {
            let port = Int.random(in: 40000..<50000)
            let transport = HTTPTransport(
                host: "127.0.0.1",
                port: port,
                database: Database(),
                resolver: ContactResolver(seedCache: [:]),
                requestTimeout: .seconds(5),
                channelIdleTimeout: channelIdleTimeout,
                cleanupInterval: .milliseconds(20)
            )
            do {
                try await transport.connect()
                await AsyncTimeout.sleep(.milliseconds(200))
                do {
                    try await body(transport, port)
                    await transport.disconnect()
                    return
                } catch {
                    await transport.disconnect()
                    throw error
                }
            } catch {
                lastError = error
            }
        }
        throw lastError ?? XCTSkip("could not bind a live HTTP port")
    }
}

private func initializeSession(port: Int) throws -> String {
    let fd = try connectLoopback(port: port)
    defer { close(fd) }
    setRecvTimeout(fd, seconds: 2)
    let body = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}}}
        """
    let post = """
        POST / HTTP/1.1\r\n\
        Host: 127.0.0.1\r\n\
        Content-Type: application/json\r\n\
        Accept: application/json, text/event-stream\r\n\
        Content-Length: \(body.utf8.count)\r\n\
        \r\n\
        \(body)
        """
    try writeAll(fd, post)
    let response = try readUntilDoubleCRLF(fd)
    return try XCTUnwrap(
        sessionId(from: response),
        "initialize response missing Mcp-Session-Id: \(response)"
    )
}

private func connectLoopback(port: Int) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { throw POSIXError(errno) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard rc == 0 else {
        close(fd)
        throw POSIXError(errno)
    }
    return fd
}

private func setRecvTimeout(_ fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

private func writeAll(_ fd: Int32, _ text: String) throws {
    try text.withCString { ptr in
        var sent = 0
        let total = strlen(ptr)
        while sent < total {
            let n = Darwin.send(fd, ptr + sent, total - sent, 0)
            if n <= 0 { throw POSIXError(errno) }
            sent += n
        }
    }
}

private func readUntilDoubleCRLF(_ fd: Int32) throws -> String {
    var collected = [UInt8]()
    var byte: UInt8 = 0
    while collected.count < 16_384 {
        let n = recv(fd, &byte, 1, 0)
        if n <= 0 { break }
        collected.append(byte)
        if collected.count >= 4,
            collected.suffix(4).elementsEqual([13, 10, 13, 10])
        {
            break
        }
    }
    return String(decoding: collected, as: UTF8.self)
}

private func sessionId(from response: String) -> String? {
    let needle = "mcp-session-id:"
    guard let range = response.lowercased().range(of: needle) else { return nil }
    let rest = response[range.upperBound...]
    let token = rest.prefix(while: { !$0.isNewline && $0 != "\r" })
    let value = token.trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? nil : String(value)
}

private struct POSIXError: Error {
    let code: Int32
    init(_ code: Int32) { self.code = code }
}
