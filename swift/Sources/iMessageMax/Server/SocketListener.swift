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
/// - The socket file is mode 0600 inside a folder only the user can write.
/// - Every accepted fd is FD_CLOEXEC and SO_NOSIGPIPE before anything else.
/// - A peer whose uid fails `peerPolicy` is closed before `serve` sees it.
/// - Nothing unlinks the path unless it is still the socket file it saw:
///   the stale-socket reclaim, a failed setup and stop() all compare inodes.
final class SocketListener: Sendable {
    typealias Serve = @Sendable (SocketTransport) async -> Void
    typealias PeerPolicy = @Sendable (_ peerUID: uid_t) -> Bool

    static let sameUser: PeerPolicy = { $0 == geteuid() }

    /// Bounds one turn of the accept handler, so a connect storm cannot hold
    /// the queue that stop() needs.
    private static let acceptsPerTurn = 32
    /// Live connections past this are accepted and closed at once, so a
    /// client that opens bridges in a loop cannot exhaust descriptors.
    static let maxConnections = 64
    /// How long accepting pauses after accept fails for a reason other than
    /// the queue being empty.
    private static let acceptBackoff: DispatchTimeInterval = .milliseconds(250)
    /// How long a live helper may take to accept the reclaim probe.
    private static let probeTimeout: Duration = .milliseconds(500)
    /// How long start waits for another helper to finish its own setup.
    private static let setupLockTimeout: Duration = .seconds(2)

    private struct State {
        var connections: [UInt64: SocketTransport] = [:]
        var nextID: UInt64 = 0
        var stopped = false
        var acceptSource: (any DispatchSourceRead)?
        var backoff: (any DispatchSourceTimer)?
        var rejections = LogThrottle(interval: .seconds(10))
        var overflows = LogThrottle(interval: .seconds(10))
        var acceptFailures = LogThrottle(interval: .seconds(10))
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

    /// Prepares the folder, reclaims a stale socket, binds 0600, listens,
    /// and starts accepting. Leaves no socket file behind when a step after
    /// bind fails.
    ///
    /// Setup can block for up to `setupLockTimeout` plus `probeTimeout`, so
    /// it runs on its own thread and no cooperative thread waits on it.
    static func start(
        at socket: SocketPath,
        peerPolicy: @escaping PeerPolicy = SocketListener.sameUser,
        serve: @escaping Serve
    ) async throws(SocketSetupError) -> SocketListener {
        let result = await withCheckedContinuation { (done: CheckedContinuation<Result<SocketListener, SocketSetupError>, Never>) in
            Thread.detachNewThread {
                done.resume(returning: Result { () throws(SocketSetupError) in
                    try startBlocking(at: socket, peerPolicy: peerPolicy, serve: serve)
                })
            }
        }
        return try result.get()
    }

    private static func startBlocking(
        at socket: SocketPath,
        peerPolicy: @escaping PeerPolicy,
        serve: @escaping Serve
    ) throws(SocketSetupError) -> SocketListener {
        do {
            switch socket.folderRule {
            case .ensurePrivate: try PrivateFolder.ensure(socket.folder)
            case .requirePrivate: try PrivateFolder.requirePrivate(socket.folder)
            }
        } catch {
            throw SocketSetupError(error)
        }
        // Two helpers starting at once would otherwise both judge the old
        // socket stale, and the second would unlink the first one's new
        // socket. Held until the new socket listens (the consume below) or
        // setup throws, so a second helper's probe finds a live socket.
        let lock = try SetupLock(beside: socket, timeout: setupLockTimeout)
        try reclaimStale(socket)

        let owned = try OwnedSocket.make(for: socket)
        guard fcntl(owned.fd, F_SETFL, fcntl(owned.fd, F_GETFL) | O_NONBLOCK) == 0 else {
            throw .posix(socket.path, "configure socket for", errno)
        }
        // bind creates the file with the process umask, so a looser umask
        // would leave it reachable until the chmod below. umask is
        // process-wide, so it changes only for this one call. Another thread
        // creating a file in this window gets 0600 at worst, never looser.
        let previousMask = umask(0o177)
        let bindResult = socket.withAddress { bind(owned.fd, $0, $1) }
        let bindError = errno
        umask(previousMask)
        guard bindResult == 0 else {
            throw bindError == EADDRINUSE ? .inUse(path: socket.path) : .posix(socket.path, "bind", bindError)
        }
        guard let bound = FileIdentity(at: socket.path) else {
            let code = errno
            // The path cannot be checked, so it is unlinked as bound. The
            // setup lock keeps a cooperating helper from binding it meanwhile.
            Darwin.unlink(socket.path)
            throw .posix(socket.path, "stat", code)
        }
        do throws(SocketSetupError) {
            guard chmod(socket.path, 0o600) == 0 else { throw .posix(socket.path, "chmod", errno) }
            guard listen(owned.fd, 64) == 0 else { throw .posix(socket.path, "listen on", errno) }
        } catch {
            bound.unlink(at: socket.path)
            throw error
        }
        _ = consume lock

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

    /// Stops accepting, unlinks the socket if it is still ours, and aborts
    /// every live connection so their sessions end and their bridges see
    /// EOF. Safe to call twice.
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
        bound.unlink(at: socket.path)
        for transport in live {
            transport.abort()
        }
    }

    /// Runs on `queue`. The listen fd is non-blocking, so this returns on
    /// EAGAIN. After `acceptsPerTurn` connections it returns anyway; the
    /// read source is level-triggered, so it fires again for the rest once
    /// other work on the queue has run.
    private func acceptPending() {
        for _ in 0..<Self.acceptsPerTurn {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                let code = errno
                switch code {
                case EAGAIN: return
                case EINTR, ECONNABORTED: continue
                // EMFILE, ENFILE, ENOBUFS, ENOMEM and the rest leave the
                // connection queued, so the source stays readable.
                default: pauseAccepting(after: code); return
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
                if let held = state.withLock({ $0.rejections.admit() }) {
                    Log.warning("socket peer uid=\(uid.map(String.init) ?? "unknown") rejected\(Self.heldNote(held))")
                }
                continue
            }
            // Only this queue adds connections, so the count cannot grow
            // between this check and the insert below.
            let overflow: (full: Bool, held: Int?) = state.withLock { state in
                guard state.connections.count >= Self.maxConnections else { return (false, nil) }
                return (true, state.overflows.admit())
            }
            if overflow.full {
                if let held = overflow.held {
                    Log.warning("socket has \(Self.maxConnections) live connections; closed a new one\(Self.heldNote(held))")
                }
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
                transport.abort()
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

    private static func heldNote(_ held: Int) -> String {
        held > 0 ? " (\(held) more since the last warning)" : ""
    }

    /// The read source is level-triggered, so after a failed accept it would
    /// spin. A cancellable timer resumes it after `acceptBackoff`.
    ///
    /// The timer is made, and resumed, only once the pause is certain:
    /// libdispatch traps when a source that was never resumed is released.
    func pauseAccepting(after code: Int32) {
        // nil: not paused, or paused with the log line held back.
        let held = state.withLock { current -> Int? in
            guard !current.stopped, current.backoff == nil, let source = current.acceptSource else { return nil }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [self] in
                let resumes = state.withLock { state in
                    guard let backoff = state.backoff else { return false }
                    backoff.cancel()
                    state.backoff = nil
                    return true
                }
                if resumes { source.resume() }
            }
            timer.schedule(deadline: .now() + Self.acceptBackoff)
            source.suspend()
            timer.resume()
            current.backoff = timer
            return current.acceptFailures.admit()
        }
        if let held {
            Log.error("socket accept failed: \(String(cString: strerror(code))); pausing 250 ms\(Self.heldNote(held))")
        }
    }

    /// Runs under the setup lock. A socket that refuses the probe is stale
    /// and is removed. One that accepts, or does not answer within
    /// `probeTimeout`, belongs to a live helper and is left alone.
    private static func reclaimStale(_ socket: SocketPath) throws(SocketSetupError) {
        var info = stat()
        guard lstat(socket.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw .posix(socket.path, "stat", errno)
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw .notASocket(path: socket.path) }
        guard info.st_uid == geteuid() else { throw .wrongOwner(path: socket.path) }
        let seen = FileIdentity(info)
        let probe = try OwnedSocket.make(for: socket)
        switch probe.connect(to: socket, deadline: .now + probeTimeout) {
        case 0, ETIMEDOUT, EAGAIN:
            throw .inUse(path: socket.path)
        case ECONNREFUSED:
            // A file that changed since the lstat is someone else's new socket.
            guard seen.unlink(at: socket.path) else { throw .inUse(path: socket.path) }
        case ENOENT:
            return
        case let code:
            throw .posix(socket.path, "probe", code)
        }
    }
}

/// Which file a path named when it was checked.
private struct FileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }

    init?(at path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        self.init(info)
    }

    /// Unlinks `path` only while it still names this file. Returns false
    /// when another file has taken the path; true when this file is gone.
    ///
    /// The lstat and the unlink are two steps, not one atomic check. Only
    /// helpers that take the setup lock are kept from swapping the path in
    /// between; any other process that can write the folder is not.
    @discardableResult
    func unlink(at path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT }
        guard FileIdentity(info) == self else { return false }
        return Darwin.unlink(path) == 0 || errno == ENOENT
    }
}

/// An exclusive flock on "<socket>.lock" in the socket's folder. The file
/// stays after release: unlinking a lock file lets a later locker hold a
/// different inode than a current one. Closing the fd releases the lock.
private struct SetupLock: ~Copyable {
    private let fd: Int32

    init(beside socket: SocketPath, timeout: Duration) throws(SocketSetupError) {
        let path = socket.path + ".lock"
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw .posix(path, "open", errno) }
        let deadline = ContinuousClock.now + timeout
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                close(fd)
                throw .posix(path, "lock", code)
            }
            guard ContinuousClock.now < deadline else {
                close(fd)
                throw .inUse(path: socket.path)
            }
            usleep(10_000)
        }
        self.fd = fd
    }

    deinit { close(fd) }
}

/// Lets one log line through per `interval` and counts the ones it held
/// back, so a peer that reconnects in a loop cannot flood stderr.
struct LogThrottle: Sendable {
    let interval: Duration
    private var lastLogged: ContinuousClock.Instant?
    private var held = 0

    init(interval: Duration) {
        self.interval = interval
    }

    /// nil: stay quiet. Otherwise log now; the value counts the lines held
    /// back since the last one.
    mutating func admit(at now: ContinuousClock.Instant = .now) -> Int? {
        if let lastLogged, lastLogged.duration(to: now) < interval {
            held += 1
            return nil
        }
        lastLogged = now
        defer { held = 0 }
        return held
    }
}

/// One accepted connection as an MCP Transport. Messages are
/// newline-delimited JSON, as on stdio.
///
/// Built on DispatchIO and Dispatch timers, so no method sleeps or blocks a
/// cooperative thread. Every bound a misbehaving peer could push against
/// lives here:
/// - Reads go in chunks of `readChunkBytes`. Before each read, reading
///   pauses while `maxQueuedMessages` or more messages sit unread, so the
///   inbox can pass the cap by at most one chunk's messages. A stalled
///   session stops reading, and the peer's writes back up in the kernel.
/// - `send` queues the bytes on the channel and returns. A peer that
///   leaves more than `maxUnsentBytes` unread is disconnected.
/// - A line over LineFramer.maxMessageBytes disconnects the peer.
/// - `disconnect` gives queued writes at most `flushTimeout`, so a peer
///   that stops reading cannot hold the fd open.
///
/// The DispatchIO handlers run off the actor, so everything they touch sits
/// in one Mutex, and no method that builds a handler is actor-isolated: a
/// closure that captures an isolated self would assert the actor's executor
/// on the dispatch queue. The channel owns the fd and closes it in its cleanup
/// handler. Nothing else closes it.
actor SocketTransport: Transport {
    static let maxQueuedMessages = 64
    static let maxUnsentBytes = 16 * 1024 * 1024
    static let flushTimeout: DispatchTimeInterval = .seconds(2)
    private static let readChunkBytes = 64 * 1024

    nonisolated let logger = Logger(label: "imessage-max.socket", factory: { _ in SwiftLogNoOpLogHandler() })

    private enum Ending {
        case finished
        case failed(any Error)

        var result: Result<Data?, any Error> {
            switch self {
            case .finished: .success(nil)
            case .failed(let error): .failure(error)
            }
        }
    }

    private enum Phase {
        case open
        /// disconnect() ran with writes queued. Nothing more is read or
        /// sent. The channel closes when the writes finish or the timer
        /// fires, whichever comes first.
        case draining(any DispatchSourceTimer)
        case closed
    }

    private struct State {
        var framer = LineFramer()
        /// Unread messages from `head` on. Popped slots are released and
        /// compacted away once they are half the array.
        var inbox: [Data] = []
        var head = 0
        /// The receiver waiting on an empty inbox.
        var waiter: CheckedContinuation<Data?, any Error>?
        /// Set once no more messages will arrive.
        var ending: Ending?
        var started = false
        var reading = false
        var chunkBytes = 0
        var phase = Phase.open
        var unsentBytes = 0

        var queued: Int { inbox.count - head }

        mutating func pop() -> Data? {
            guard head < inbox.count else { return nil }
            let message = inbox[head]
            inbox[head] = Data()
            head += 1
            if head * 2 >= inbox.count {
                inbox.removeFirst(head)
                head = 0
            }
            return message
        }
    }

    private nonisolated let channel: DispatchIO
    private nonisolated let queue: DispatchQueue
    private nonisolated let state = Mutex(State())

    init(adopting socket: consuming OwnedSocket) {
        let fd = socket.release()
        let queue = DispatchQueue(label: "imessage-max.socket.connection")
        self.queue = queue
        channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue, cleanupHandler: { _ in Darwin.close(fd) })
        channel.setLimit(lowWater: 1)
    }

    /// Starts reading. A second call does nothing.
    func connect() async throws {
        let first = state.withLock { state in
            defer { state.started = true }
            return !state.started
        }
        if first { readNextChunk() }
    }

    /// Ends the session from the server side. Reading stops at once.
    /// Writes already queued get up to `flushTimeout` to reach the peer,
    /// then the fd closes whether or not they did. DualEraStdio queues its
    /// last send before it disconnects. A second call does nothing.
    func disconnect() async {
        end(flushing: true)
    }

    /// Ends the connection now and drops queued writes and unread messages,
    /// so the session ends and the bridge reads EOF. For listener shutdown
    /// and peers that break a bound. Also cuts short a disconnect's flush.
    nonisolated func abort() {
        end(flushing: false)
    }

    /// Appends "\n" and queues the bytes; never raises SIGPIPE. Throws
    /// ENOTCONN once disconnect or abort has run, and ENOBUFS when this
    /// send would leave more than `maxUnsentBytes` unwritten, after
    /// aborting the connection.
    nonisolated func send(_ data: Data) async throws {
        var bytes = data
        bytes.append(0x0A)
        let size = bytes.count
        let admitted: Bool? = state.withLock { state in
            guard case .open = state.phase else { return nil }
            state.unsentBytes += size
            return state.unsentBytes <= Self.maxUnsentBytes
        }
        guard let admitted else { throw MCPError.transportError(POSIXError(.ENOTCONN)) }
        guard admitted else {
            Log.warning("socket peer left over \(Self.maxUnsentBytes) bytes unread; closing the connection")
            abort()
            throw MCPError.transportError(POSIXError(.ENOBUFS))
        }
        let payload = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: payload, queue: queue) { [self] done, _, error in
            guard done else { return }
            let flushed = state.withLock { state in
                state.unsentBytes -= size
                return state.unsentBytes == 0
            }
            // EPIPE: the peer has gone. ECANCELED: already closed.
            if error != 0 {
                abort()
            } else if flushed {
                closeIfDraining()
            }
        }
    }

    nonisolated func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream(unfolding: { [self] in try await nextMessage() })
    }

    private nonisolated func nextMessage() async throws -> Data? {
        let message: Data? = try await withCheckedThrowingContinuation { continuation in
            let ready: Result<Data?, any Error>? = state.withLock { state in
                if let message = state.pop() { return .success(message) }
                guard let ending = state.ending else {
                    state.waiter = continuation
                    return nil
                }
                return ending.result
            }
            if let ready { continuation.resume(with: ready) }
        }
        readNextChunk()
        return message
    }

    /// Issues the next read unless one is outstanding, the inbox is full,
    /// or reading has ended. Every pop calls it, so a paused read resumes
    /// once the session catches up.
    private nonisolated func readNextChunk() {
        let reads = state.withLock { state in
            guard state.started, !state.reading, state.ending == nil,
                  state.queued < Self.maxQueuedMessages
            else { return false }
            state.reading = true
            state.chunkBytes = 0
            return true
        }
        guard reads else { return }
        channel.read(offset: 0, length: Self.readChunkBytes, queue: queue) { [self] done, data, error in
            if let data, !data.isEmpty { take(data) }
            guard done else { return }
            let filled = state.withLock { state in
                state.reading = false
                return state.chunkBytes == Self.readChunkBytes
            }
            switch error {
            case 0 where filled: readNextChunk()
            case 0, ECANCELED: finishReading(.finished)
            default: finishReading(.failed(MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))))
            }
        }
    }

    private nonisolated func take(_ data: DispatchData) {
        let handoff: Result<(CheckedContinuation<Data?, any Error>, Data)?, LineFramer.Oversized> = state.withLock { state in
            state.chunkBytes += data.count
            do throws(LineFramer.Oversized) {
                state.inbox.append(contentsOf: try state.framer.append(data))
            } catch {
                return .failure(error)
            }
            guard let waiter = state.waiter, let message = state.pop() else { return .success(nil) }
            state.waiter = nil
            return .success((waiter, message))
        }
        switch handoff {
        case .success(let ready?):
            ready.0.resume(returning: ready.1)
        case .success(nil):
            break
        case .failure(let error):
            Log.warning("socket message over \(LineFramer.maxMessageBytes) bytes; closing the connection")
            finishReading(.failed(MCPError.transportError(error)))
            abort()
        }
    }

    /// No more messages will arrive. The receiver gets what is queued, then
    /// the ending.
    private nonisolated func finishReading(_ ending: Ending) {
        let waiter = state.withLock { state in
            if state.ending == nil { state.ending = ending }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(with: ending.result)
    }

    /// Sets the ending in the same lock section that decides how to close,
    /// so readNextChunk cannot start a read after it. Closes with .stop,
    /// which cancels an outstanding read instead of waiting on the peer.
    private nonisolated func end(flushing: Bool) {
        let (waiter, closesNow) = state.withLock { state in
            if state.ending == nil { state.ending = .finished }
            defer { state.waiter = nil }
            if !flushing {
                state.inbox = []
                state.head = 0
            }
            switch state.phase {
            case .closed:
                return (state.waiter, false)
            case .draining(let timer):
                guard !flushing else { return (state.waiter, false) }
                timer.cancel()
                state.phase = .closed
                return (state.waiter, true)
            case .open:
                guard flushing, state.unsentBytes > 0 else {
                    state.phase = .closed
                    return (state.waiter, true)
                }
                // Resumed under the lock, so no path can release it unresumed.
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.setEventHandler { [self] in closeIfDraining() }
                timer.schedule(deadline: .now() + Self.flushTimeout)
                timer.resume()
                state.phase = .draining(timer)
                return (state.waiter, false)
            }
        }
        // A waiter means the inbox was empty and no ending was set before.
        waiter?.resume(returning: nil)
        if closesNow { channel.close(flags: .stop) }
    }

    /// Ends a disconnect's flush: its writes finished, or its time ran out.
    private nonisolated func closeIfDraining() {
        let timer: (any DispatchSourceTimer)? = state.withLock { state in
            guard case .draining(let timer) = state.phase else { return nil }
            state.phase = .closed
            return timer
        }
        guard let timer else { return }
        timer.cancel()
        channel.close(flags: .stop)
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
