import Darwin
import Foundation
import XCTest
@testable import iMessageMax

struct SocketTestTimeout: Error {}

/// sun_path holds 104 bytes, so test sockets live in a short folder.
func makeShortTempFolder() throws -> String {
    var template = Array("/private/tmp/imax-XXXXXX".utf8CString)
    guard mkdtemp(&template) != nil else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func testSocketPath(in folder: String, name: String = "s.sock") throws -> SocketPath {
    try SocketPath.resolve(override: "\(folder)/\(name)")
}

/// A blocking client connection, the way a bridge or a stale probe makes one.
func connectClient(_ socket: SocketPath) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    guard socket.withAddress({ connect(fd, $0, $1) }) == 0 else {
        let code = errno
        close(fd)
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    return fd
}

func writeLine(_ fd: Int32, _ line: String) {
    let bytes = Array((line + "\n").utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
        if written < 0 {
            if errno == EINTR { continue }
            XCTFail("write failed: \(String(cString: strerror(errno)))")
            return
        }
        offset += written
    }
}

/// Reads newline-delimited lines from a blocking fd. Every read waits at
/// most `timeout`, so a missing reply fails the test instead of hanging it.
final class LineReader {
    let fd: Int32
    private var pending: [UInt8] = []

    init(_ fd: Int32) {
        self.fd = fd
    }

    /// nil at EOF.
    func nextLine(timeout: TimeInterval = 10) throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SocketTestTimeout() }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(remaining * 1000) + 1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw SocketTestTimeout() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == ECONNRESET { return nil }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { return nil }
            pending += buffer[..<count]
        }
    }

    func nextJSON(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let text = try XCTUnwrap(try nextLine(timeout: timeout), "EOF before a reply", file: file, line: line)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], "not a JSON object: \(text)",
            file: file, line: line)
    }
}
