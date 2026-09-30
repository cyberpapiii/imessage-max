import Foundation
import os

/// POSIX Unix-domain-socket transport to the injected helper. Production
/// connects to `path`; tests wrap a pre-connected fd (e.g. from socketpair()).
final class UnixSocketTransport: HelperTransport, @unchecked Sendable {
    private let path: String?
    private var fd: Int32
    private let lock = OSAllocatedUnfairLock()

    init(path: String) { self.path = path; self.fd = -1 }
    init(connectedFD fd: Int32) { self.path = nil; self.fd = fd }

    func isConnected() async -> Bool {
        lock.withLock {
            return ensureConnectedLocked()
        }
    }

    func roundTrip(_ request: Data, timeout: TimeInterval) async throws -> Data {
        try lock.withLock {
            guard ensureConnectedLocked() else { throw HelperError.notConnected }

            // Apply send/recv timeout on the fd.
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            let wrote = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard wrote == request.count else { throw HelperError.notConnected }

            var out = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buf, buf.count)
                if n < 0 { throw HelperError.timeout }
                if n == 0 { break } // peer closed
                out.append(contentsOf: buf[0..<n])
                if let nl = out.firstIndex(of: 0x0A) {
                    return out.prefix(upToBoundary: nl)
                }
            }
            if let nl = out.firstIndex(of: 0x0A) { return out.prefix(upToBoundary: nl) }
            return out
        }
    }

    /// Connects to `path` if not already connected. A wrapped fd is always
    /// considered connected. Returns false on failure.
    private func ensureConnectedLocked() -> Bool {
        if fd >= 0 { return true }
        guard let path else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path) - 1
        _ = withUnsafeMutablePointer(to: &addr) { addrPtr in
            path.withCString { c in
                strncpy(&addrPtr.pointee.sun_path.0, c, pathSize)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) }
        }
        if rc != 0 { close(s); return false }
        fd = s
        return true
    }
}

private extension Data {
    /// Bytes before `boundary` (a `\n` index), excluding the newline.
    func prefix(upToBoundary boundary: Index) -> Data { subdata(in: startIndex..<boundary) }
}
