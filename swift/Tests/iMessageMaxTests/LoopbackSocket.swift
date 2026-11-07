import Darwin
import XCTest

func freeLoopbackPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { throw SocketError(errno) }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let rc = withUnsafeMutablePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, length) == 0 ? getsockname(fd, $0, &length) : -1
        }
    }
    guard rc == 0 else { throw SocketError(errno) }
    return Int(in_port_t(bigEndian: addr.sin_port))
}

func initializeSession(port: Int, authorization: String = testAuthorization) throws -> String {
    let fd = try connectLoopback(port: port)
    defer { close(fd) }
    setRecvTimeout(fd, seconds: 2)
    let body = initializeBody()
    let post = """
        POST / HTTP/1.1\r\n\
        Host: 127.0.0.1\r\n\
        Authorization: \(authorization)\r\n\
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

func connectLoopback(port: Int) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { throw SocketError(errno) }
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
        throw SocketError(errno)
    }
    return fd
}

func setRecvTimeout(_ fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

func writeAll(_ fd: Int32, _ text: String) throws {
    try text.withCString { ptr in
        var sent = 0
        let total = strlen(ptr)
        while sent < total {
            let n = Darwin.send(fd, ptr + sent, total - sent, 0)
            if n <= 0 { throw SocketError(errno) }
            sent += n
        }
    }
}

func readUntilDoubleCRLF(_ fd: Int32) throws -> String {
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

func sessionId(from response: String) -> String? {
    let needle = "mcp-session-id:"
    guard let range = response.lowercased().range(of: needle) else { return nil }
    let rest = response[range.upperBound...]
    let token = rest.prefix(while: { !$0.isNewline && $0 != "\r" })
    let value = token.trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? nil : String(value)
}

struct SocketError: Error {
    let code: Int32
    init(_ code: Int32) { self.code = code }
}
