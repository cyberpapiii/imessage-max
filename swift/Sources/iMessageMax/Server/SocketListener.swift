import Darwin
import Dispatch
import Foundation
import Logging
import MCP
import Synchronization

/// Accepts stdio-bridge connections on a Unix socket and hands each one, as
/// an MCP Transport, to `serve`. Knows nothing about MCP itself.
///
/// Invariants:
/// - The socket file is mode 0600 inside a folder only the user can reach.
/// - Every accepted fd is FD_CLOEXEC and SO_NOSIGPIPE before anything else.
/// - A peer whose uid fails `peerPolicy` is closed before `serve` sees it.
/// - stop() is idempotent and unlinks the path only if it is still the
///   socket this listener bound.
final class SocketListener: Sendable {
    typealias Serve = @Sendable (SocketTransport) async -> Void
    typealias PeerPolicy = @Sendable (_ peerUID: uid_t) -> Bool

    static let sameUser: PeerPolicy = { $0 == geteuid() }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct State {
        var connections: [UInt64: SocketTransport] = [:]
        var nextID: UInt64 = 0
        var stopped = false
        var acceptSource: (any DispatchSourceRead)?
        var backoff: (any DispatchSourceTimer)?
    }

    private let state = Mutex(State())
    private let socket: SocketPath
    private let bound: FileIdentity
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "imessage-max.socket.accept")
    private let peerPolicy: PeerPolicy
    private let serve: Serve

    private init(socket: SocketPath, bound: FileIdentity, listenFD: Int32, peerPolicy: @escaping PeerPolicy, serve: @escaping Serve) {
        self.socket = socket
        self.bound = bound
        self.listenFD = listenFD
        self.peerPolicy = peerPolicy
        self.serve = serve
    }

    /// Prepares the folder, reclaims a stale socket, binds, sets 0600,
    /// listens, and starts accepting. Leaves no socket file behind when a
    /// step after bind fails.
    static func start(
        at socket: SocketPath,
        peerPolicy: @escaping PeerPolicy = SocketListener.sameUser,
        serve: @escaping Serve
    ) throws(SocketSetupError) -> SocketListener {
        do {
            switch socket.folderRule {
            case .ensurePrivate: try PrivateFolder.ensure(socket.folder)
            case .requireOwned: try PrivateFolder.requireOwned(socket.folder)
            }
        } catch {
            throw SocketSetupError(error)
        }
        try reclaimStale(socket)

        let owned = try OwnedSocket.make(for: socket)
        guard fcntl(owned.fd, F_SETFL, fcntl(owned.fd, F_GETFL) | O_NONBLOCK) == 0 else {
            throw .posix(socket.path, "configure socket for", errno)
        }
        guard socket.withAddress({ bind(owned.fd, $0, $1) }) == 0 else {
            let code = errno
            throw code == EADDRINUSE ? .inUse(path: socket.path) : .posix(socket.path, "bind", code)
        }
        let bound: FileIdentity
        do throws(SocketSetupError) {
            // umask is process-wide, so the mode is set after bind. The 0700
            // folder covers the gap.
            guard chmod(socket.path, 0o600) == 0 else { throw .posix(socket.path, "chmod", errno) }
            var info = stat()
            guard lstat(socket.path, &info) == 0 else { throw .posix(socket.path, "stat", errno) }
            bound = FileIdentity(device: info.st_dev, inode: info.st_ino)
            guard listen(owned.fd, 64) == 0 else { throw .posix(socket.path, "listen on", errno) }
        } catch {
            unlink(socket.path)
            throw error
        }

        let fd = owned.release()
        let listener = SocketListener(socket: socket, bound: bound, listenFD: fd, peerPolicy: peerPolicy, serve: serve)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: listener.queue)
        source.setEventHandler { listener.acceptPending() }
        source.setCancelHandler { close(fd) }
        listener.state.withLock { $0.acceptSource = source }
        source.resume()
        Log.info("Socket listening path=\(socket)")
        return listener
    }

    /// Stops accepting, unlinks the socket if it is still ours, and
    /// disconnects every live connection so their sessions end and their
    /// bridges see EOF. Safe to call twice.
    func stop() async {
        let live: [SocketTransport]? = state.withLock { state in
            guard !state.stopped else { return nil }
            state.stopped = true
            return Array(state.connections.values)
        }
        guard let live else { return }
        queue.async { [self] in
            let (source, backoff) = state.withLock { state in
                defer { state.acceptSource = nil; state.backoff = nil }
                return (state.acceptSource, state.backoff)
            }
            if let backoff {
                backoff.cancel()
                source?.resume()
            }
            source?.cancel()
        }
        var info = stat()
        if lstat(socket.path, &info) == 0, FileIdentity(device: info.st_dev, inode: info.st_ino) == bound {
            unlink(socket.path)
        }
        for transport in live {
            await transport.disconnect()
        }
    }

    /// Runs on `queue`. The listen fd is non-blocking, so this drains every
    /// pending connection and returns on EAGAIN.
    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                switch errno {
                case EAGAIN: return
                case EINTR, ECONNABORTED: continue
                case EMFILE, ENFILE: pauseAccepting(); return
                default:
                    Log.error("socket accept failed: \(String(cString: strerror(errno)))")
                    return
                }
            }
            let owned: OwnedSocket
            do {
                owned = try OwnedSocket(adopting: fd, path: socket.path)
            } catch {
                Log.error("socket connection dropped: \(error)")
                continue
            }
            let uid = owned.peerUID()
            guard let uid, peerPolicy(uid) else {
                Log.warning("socket peer uid=\(uid.map(String.init) ?? "unknown") rejected")
                continue
            }
            let transport = SocketTransport(adopting: owned)
            let id: UInt64? = state.withLock { state in
                guard !state.stopped else { return nil }
                state.nextID += 1
                state.connections[state.nextID] = transport
                return state.nextID
            }
            guard let id else {
                Task { await transport.disconnect() }
                continue
            }
            Log.info("socket connection opened id=\(id)")
            Task { [self] in
                await serve(transport)
                state.withLock { _ = $0.connections.removeValue(forKey: id) }
                Log.info("socket connection closed id=\(id)")
            }
        }
    }

    /// The read source is level-triggered, so out of descriptors it would
    /// spin. A cancellable timer resumes it after 250 ms.
    private func pauseAccepting() {
        Log.error("socket accept: out of file descriptors; pausing 250 ms")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let source: (any DispatchSourceRead)? = state.withLock { state in
            guard !state.stopped, state.backoff == nil else { return nil }
            state.backoff = timer
            return state.acceptSource
        }
        guard let source else { return }
        source.suspend()
        timer.setEventHandler { [self] in
            let resumes = state.withLock { state in
                guard let backoff = state.backoff else { return false }
                backoff.cancel()
                state.backoff = nil
                return true
            }
            if resumes { source.resume() }
        }
        timer.schedule(deadline: .now() + .milliseconds(250))
        timer.resume()
    }

    private static func reclaimStale(_ socket: SocketPath) throws(SocketSetupError) {
        var info = stat()
        guard lstat(socket.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw .posix(socket.path, "stat", errno)
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw .notASocket(path: socket.path) }
        guard info.st_uid == geteuid() else { throw .wrongOwner(path: socket.path) }
        let probe = try OwnedSocket.make(for: socket)
        switch probe.connect(to: socket) {
        case 0:
            throw .inUse(path: socket.path)
        case ECONNREFUSED:
            if unlink(socket.path) != 0, errno != ENOENT {
                throw .posix(socket.path, "remove stale socket", errno)
            }
        case ENOENT:
            return
        case let code:
            throw .posix(socket.path, "probe", code)
        }
    }
}

/// One accepted connection as an MCP Transport. Messages are
/// newline-delimited JSON, as on stdio.
///
/// Built on DispatchIO, so it never sleeps and never blocks a cooperative
/// thread. Reads arrive as soon as one byte is available. Writes are queued
/// on the channel in submission order, and `send` resumes when the kernel
/// has taken every byte.
///
/// The channel owns the fd and closes it in its cleanup handler. Nothing
/// else closes it.
actor SocketTransport: Transport {
    nonisolated let logger = Logger(label: "imessage-max.socket", factory: { _ in SwiftLogNoOpLogHandler() })

    private enum Phase { case idle, reading, closed }

    private let channel: DispatchIO
    private let queue: DispatchQueue
    private let messages: AsyncThrowingStream<Data, Error>
    private let sink: AsyncThrowingStream<Data, Error>.Continuation
    private var phase = Phase.idle

    init(adopting socket: consuming OwnedSocket) {
        let fd = socket.release()
        let queue = DispatchQueue(label: "imessage-max.socket.connection")
        self.queue = queue
        channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue, cleanupHandler: { _ in close(fd) })
        (messages, sink) = AsyncThrowingStream.makeStream()
    }

    /// Starts the single read. A second call does nothing.
    func connect() async throws {
        guard phase == .idle else { return }
        phase = .reading
        let framer = SharedFramer()
        let channel = self.channel
        let sink = self.sink
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
            if let data, !data.isEmpty {
                do {
                    for message in try framer.append(data) {
                        sink.yield(message)
                    }
                } catch {
                    Log.warning("socket message over \(LineFramer.maxMessageBytes) bytes; closing the connection")
                    sink.finish(throwing: MCPError.transportError(error))
                    channel.close(flags: .stop)
                    return
                }
            }
            guard done else { return }
            if error == 0 || error == ECANCELED {
                sink.finish()
            } else {
                sink.finish(throwing: MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)))
            }
        }
    }

    /// Closes the channel with .stop, so a read parked on an idle
    /// connection ends too, then finishes the inbound stream. Safe because
    /// DualEraStdio awaits its last send before it disconnects. A second
    /// call does nothing.
    func disconnect() async {
        guard phase != .closed else { return }
        phase = .closed
        channel.close(flags: .stop)
        sink.finish()
    }

    /// Appends "\n" and queues the bytes. Throws when the peer has gone;
    /// never raises SIGPIPE.
    func send(_ data: Data) async throws {
        guard phase != .closed else { throw MCPError.transportError(POSIXError(.ENOTCONN)) }
        var bytes = data
        bytes.append(0x0A)
        let payload = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        let channel = self.channel
        let queue = self.queue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            channel.write(offset: 0, data: payload, queue: queue) { done, _, error in
                guard done else { return }
                if error == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)))
                }
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Error> { messages }
}

private final class SharedFramer: Sendable {
    private let framer = Mutex(LineFramer())

    func append(_ bytes: DispatchData) throws(LineFramer.Oversized) -> [Data] {
        try framer.withLock { framer throws(LineFramer.Oversized) in try framer.append(bytes) }
    }
}

/// Splits a byte stream into messages at "\n". Pure, so tests cover partial
/// lines, empty lines and the size cap without a socket.
struct LineFramer: Sendable {
    /// The same cap the HTTP lane puts on one request body.
    static let maxMessageBytes = HTTPRequestParsing.maxRequestBodyBytes

    struct Oversized: Error {}

    private var pending = Data()

    /// Returns every complete, non-empty line in order. Throws when the
    /// unterminated tail grows past the cap.
    mutating func append(_ bytes: some Sequence<UInt8>) throws(Oversized) -> [Data] {
        var scan = pending.count
        pending.append(contentsOf: bytes)
        var lines: [Data] = []
        var start = 0
        while let newline = pending[scan...].firstIndex(of: 0x0A) {
            if newline > start {
                lines.append(pending.subdata(in: start..<newline))
            }
            start = newline + 1
            scan = start
        }
        if start > 0 {
            pending.removeSubrange(0..<start)
        }
        guard pending.count <= Self.maxMessageBytes else { throw Oversized() }
        return lines
    }
}
