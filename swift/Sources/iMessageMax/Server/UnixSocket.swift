import Darwin
import Foundation
import IMessageMaxContract

/// An absolute filesystem path that fits sockaddr_un.sun_path. Only
/// `resolve` creates one, so every SocketPath can be bound or connected.
struct SocketPath: Sendable, Equatable, CustomStringConvertible {
    enum FolderRule: Sendable, Equatable {
        /// The default app-support folder: the helper creates it 0700.
        case ensurePrivate
        /// --socket-path or the temp fallback: must exist, be owned, and
        /// give no one else write access.
        case requirePrivate
    }

    let path: String
    /// What the helper may do to the parent folder. The bridge never
    /// creates folders and always applies requirePrivate.
    let folderRule: FolderRule

    /// 103 on Darwin: sizeof(sun_path) minus the NUL.
    static let maxBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    private init(path: String, folderRule: FolderRule) {
        self.path = path
        self.folderRule = folderRule
    }

    var folder: String { (path as NSString).deletingLastPathComponent }
    var description: String { path }

    /// The one rule both helper and bridge use. Pure: no filesystem access.
    ///
    /// An override must be absolute after tilde expansion and fit. Without
    /// one, the app-support path is used when it fits, else the per-user
    /// temp folder.
    ///
    /// `home` defaults to the account record, not $HOME, so a client that
    /// rewrites HOME still finds the helper. `userTempDir` defaults to
    /// confstr(_CS_DARWIN_USER_TEMP_DIR), which every process of the user
    /// shares regardless of environment.
    static func resolve(
        override: String?,
        home: String = SocketPath.accountHome(),
        userTempDir: String? = SocketPath.darwinUserTempDir()
    ) throws(SocketSetupError) -> SocketPath {
        if let override {
            let expanded = (override as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw .relativePath(override) }
            guard fits(expanded) else { throw .pathTooLong(path: expanded, bytes: expanded.utf8.count) }
            return SocketPath(path: expanded, folderRule: .requirePrivate)
        }
        let standard = (home as NSString).appendingPathComponent(ServiceDefaults.socketPath)
        if fits(standard) {
            return SocketPath(path: standard, folderRule: .ensurePrivate)
        }
        if let userTempDir, userTempDir.hasPrefix("/") {
            let fallback = (userTempDir as NSString).appendingPathComponent(ServiceDefaults.fallbackSocketName)
            if fits(fallback) {
                return SocketPath(path: fallback, folderRule: .requirePrivate)
            }
        }
        throw .pathTooLong(path: standard, bytes: standard.utf8.count)
    }

    private static func fits(_ path: String) -> Bool {
        path.utf8.count <= maxBytes && !path.utf8.contains(0)
    }

    static func accountHome() -> String {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        if getpwuid_r(geteuid(), &record, &buffer, buffer.count, &result) == 0, let entry = result, let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    static func darwinUserTempDir() -> String? {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Builds a sockaddr_un and calls `body`. Cannot fail: the length was
    /// proven in resolve.
    func withAddress<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> R) rethrows -> R {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

enum SocketSetupError: Error, Equatable, CustomStringConvertible {
    case relativePath(String)
    case pathTooLong(path: String, bytes: Int)
    case unsafeFolder(path: String)
    /// Something other than a socket sits at the path. Left alone.
    case notASocket(path: String)
    /// A socket owned by another user sits at the path. Left alone.
    case wrongOwner(path: String)
    /// Another live helper answers on the path.
    case inUse(path: String)
    case io(path: String, operation: String, reason: String)

    static func posix(_ path: String, _ operation: String, _ code: Int32) -> SocketSetupError {
        .io(path: path, operation: operation, reason: String(cString: strerror(code)))
    }

    init(_ failure: PrivateFolder.Failure) {
        switch failure {
        case .notAFolder(let path), .wrongOwner(let path), .notOwnedFolder(let path), .writableByOthers(let path):
            self = .unsafeFolder(path: path)
        case .missing(let path):
            self = .posix(path, "find folder", ENOENT)
        case .io(let path, let operation, let reason):
            self = .io(path: path, operation: operation, reason: reason)
        }
    }

    var description: String {
        switch self {
        case .relativePath(let path):
            "Socket path \(path) is relative. Pass --socket-path with an absolute path."
        case .pathTooLong(let path, let bytes):
            "Socket path \(path) is \(bytes) bytes; macOS allows \(SocketPath.maxBytes). Pass --socket-path with a shorter path."
        case .unsafeFolder(let path):
            "Folder \(path) belongs to another user, is not a folder, or others can write to it. Pass --socket-path with a path in a private folder you own."
        case .notASocket(let path):
            "\(path) exists and is not a socket, so the server left it alone. Remove it, or pass --socket-path with another path."
        case .wrongOwner(let path):
            "Socket \(path) belongs to another user. Remove it, or pass --socket-path with a path you own."
        case .inUse(let path):
            "Another iMessage Max already listens on \(path)."
        case .io(let path, let operation, let reason):
            "Cannot \(operation) \(path): \(reason)"
        }
    }
}

/// Sole owner of one socket descriptor. Closing is the deinit, so every
/// early exit (peer rejected, setup failed) closes it with no extra code.
/// `release()` is the one hand-off point: after it, the new owner closes it.
struct OwnedSocket: ~Copyable {
    let fd: Int32

    /// A new AF_UNIX stream socket.
    static func make(for socket: SocketPath) throws(SocketSetupError) -> OwnedSocket {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .posix(socket.path, "create socket for", errno) }
        return try OwnedSocket(adopting: fd, path: socket.path)
    }

    /// Takes ownership. Sets FD_CLOEXEC and SO_NOSIGPIPE first, so the fd
    /// never leaks into osascript and a write to a departed peer returns
    /// EPIPE instead of raising SIGPIPE.
    init(adopting fd: Int32, path: String) throws(SocketSetupError) {
        var on: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            let code = errno
            close(fd)
            throw .posix(path, "configure socket for", code)
        }
        self.fd = fd
    }

    /// The peer's effective uid.
    func peerUID() -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// Connects to `socket` without waiting past `deadline`, then leaves the
    /// fd blocking again. Returns 0 or the errno, ETIMEDOUT when the
    /// deadline passes first.
    func connect(to socket: SocketPath, deadline: ContinuousClock.Instant) -> Int32 {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return errno }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        if socket.withAddress({ Darwin.connect(fd, $0, $1) }) == 0 { return 0 }
        guard errno == EINPROGRESS || errno == EINTR else { return errno }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline) / .milliseconds(1)
            let milliseconds = Int32(clamping: Int64(max(0, remaining.rounded(.up))))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            if ready < 0 { return errno }
            if ready == 0 { return ETIMEDOUT }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 ? error : errno
        }
    }

    consuming func release() -> Int32 {
        let fd = self.fd
        discard self
        return fd
    }

    deinit { close(fd) }
}
