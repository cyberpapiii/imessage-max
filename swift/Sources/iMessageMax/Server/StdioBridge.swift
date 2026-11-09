import Darwin
import Foundation
import Synchronization
import SystemConfiguration

/// How a bridge run ended. One exit code per case, and one client-facing
/// message for each way the bridge never reached a helper.
enum BridgeOutcome: Equatable, Sendable {
    /// The client closed stdin and the helper drained and closed, or the
    /// client stopped reading stdout.
    case finished
    /// Never connected. The first request on stdin got a JSON-RPC error.
    case helperUnavailable(Unavailable)
    /// The helper closed the connection mid-session (restart, crash,
    /// update) and did not come back within the grace. Every request still
    /// waiting got a JSON-RPC error.
    case helperDisconnected(Unavailable)
    /// A read or write failed for a reason other than the peer leaving.
    case ioFailure(String)

    enum Unavailable: Error, Equatable, Sendable {
        /// Nothing listens on the socket once the grace has passed.
        case notRunning
        /// Nothing listens, and this user has no desktop login, which the
        /// helper needs: launchd starts it only inside one.
        case noDesktopLogin
        /// The process serving the socket runs as another user.
        case foreignPeer(uid: uid_t)
        /// The socket's folder is not a folder you own.
        case unsafeFolder(path: String)
        case connectFailed(reason: String)

        var message: String {
            switch self {
            case .notRunning:
                "iMessage Max is not running. Open iMessage Max to start it."
            case .noDesktopLogin:
                "iMessage Max is not running, and \(NSUserName()) is not logged in to this Mac's desktop. iMessage Max runs only inside a desktop login, so it cannot start from SSH alone. Log in on the Mac's screen or through Screen Sharing, or turn on automatic login, and stay logged in."
            case .foreignPeer(let uid):
                "The iMessage Max socket is served by another user (uid \(uid)). Open iMessage Max in your own account to start it."
            case .unsafeFolder(let path):
                "Folder \(path) belongs to another user, is not a folder, or others can write to it. Pass --socket-path with a path in a private folder you own."
            case .connectFailed(let reason):
                "Cannot connect to iMessage Max: \(reason). Quit and reopen iMessage Max."
            }
        }
    }

    /// 0, EX_UNAVAILABLE (69), EX_TEMPFAIL (75), EX_IOERR (74).
    var exitCode: Int32 {
        switch self {
        case .finished: 0
        case .helperUnavailable: EX_UNAVAILABLE
        case .helperDisconnected: EX_TEMPFAIL
        case .ioFailure: EX_IOERR
        }
    }
}

/// Copies stdio to and from the helper's socket so a client-spawned process
/// never needs Full Disk Access, Contacts or Automation itself.
///
/// A helper restart (update, crash, Keep running relaunch) does not end the
/// client's session. The bridge reconnects within the grace and replays the
/// client's `initialize` and `notifications/initialized`, so a legacy
/// session carries on with no new initialize from the client. Modern-era
/// requests are stateless and need no replay.
enum StdioBridge {
    /// Covers launchd's 10 s ThrottleInterval, both for a client that
    /// starts while the helper is relaunching and for a reconnect.
    static let defaultConnectGrace: Duration = .seconds(15)
    /// Retries start at the first interval and double up to the last.
    fileprivate static let retryIntervals: (first: Duration, last: Duration) = (.milliseconds(100), .milliseconds(500))
    fileprivate static let chunkBytes = 64 * 1024

    /// Copies `input` to the helper's socket and the socket to `output`
    /// until the client leaves, or the helper leaves and does not come back
    /// within `connectGrace`. Never closes `input` or `output`; the caller
    /// owns them. `hasDesktopLogin` says whether this user has a desktop
    /// login, to explain a helper that never comes up.
    ///
    /// Runs on its own threads, so no cooperative thread blocks.
    static func run(
        socket: SocketPath,
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        connectGrace: Duration = defaultConnectGrace,
        hasDesktopLogin: @escaping @Sendable () -> Bool = { DesktopLogin.isLoggedIn() }
    ) async -> BridgeOutcome {
        await withCheckedContinuation { done in
            Thread.detachNewThread {
                let outcome: BridgeOutcome
                switch connect(socket, grace: connectGrace) {
                case .failure(let reason):
                    let reason = explain(reason, hasDesktopLogin: hasDesktopLogin)
                    Log.error(reason.message)
                    answerFirstRequest(input: input, output: output, with: reason)
                    outcome = .helperUnavailable(reason)
                case .success(let owned):
                    let session = BridgeSession(
                        socket: socket, input: input, output: output, grace: connectGrace,
                        hasDesktopLogin: hasDesktopLogin)
                    outcome = session.run(first: BridgeConnection(owned))
                }
                done.resume(returning: outcome)
            }
        }
    }

    /// A helper that is not running on a Mac where this user has no desktop
    /// login cannot be started by opening the app; say what will work.
    fileprivate static func explain(
        _ reason: BridgeOutcome.Unavailable, hasDesktopLogin: () -> Bool
    ) -> BridgeOutcome.Unavailable {
        reason == .notRunning && !hasDesktopLogin() ? .noDesktopLogin : reason
    }

    /// Returns 0 or the errno of the failed write.
    fileprivate static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Int32 {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if written < 0 {
                if errno == EINTR { continue }
                return errno
            }
            offset += written
        }
        return 0
    }

    /// Blocking, but never past `grace`. Retries a missing socket or folder,
    /// and a refused connect, every 100 to 500 ms until `grace` passes. A
    /// connect the helper does not accept by then fails. Checks the folder
    /// with PrivateFolder.requirePrivate and never creates it. Checks the
    /// server's uid after connecting.
    static func connect(_ socket: SocketPath, grace: Duration) -> Result<OwnedSocket, BridgeOutcome.Unavailable> {
        let clock = ContinuousClock()
        let deadline = clock.now + grace
        var interval = retryIntervals.first
        while true {
            switch attempt(socket, deadline: deadline) {
            case .connected(let owned):
                return .success(owned)
            case .failed(let reason):
                return .failure(reason)
            case .notListening:
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { return .failure(.notRunning) }
                pause(min(remaining, interval))
                interval = min(interval * 2, retryIntervals.last)
            }
        }
    }

    fileprivate enum Attempt: ~Copyable {
        case connected(OwnedSocket)
        case notListening
        case failed(BridgeOutcome.Unavailable)
    }

    fileprivate static func attempt(_ socket: SocketPath, deadline: ContinuousClock.Instant) -> Attempt {
        do {
            try PrivateFolder.requirePrivate(socket.folder)
        } catch .missing {
            return .notListening
        } catch .notOwnedFolder(let path), .writableByOthers(let path) {
            return .failed(.unsafeFolder(path: path))
        } catch {
            return .failed(.connectFailed(reason: SocketSetupError(error).description))
        }
        let owned: OwnedSocket
        do {
            owned = try OwnedSocket.make(for: socket)
        } catch {
            return .failed(.connectFailed(reason: error.description))
        }
        switch owned.connect(to: socket, deadline: deadline) {
        case 0:
            guard let uid = owned.peerUID() else {
                return .failed(.connectFailed(reason: "cannot read the server's user id"))
            }
            guard uid == geteuid() else { return .failed(.foreignPeer(uid: uid)) }
            return .connected(owned)
        case ENOENT, ECONNREFUSED, EAGAIN:
            return .notListening
        case ETIMEDOUT:
            return .failed(.connectFailed(reason: "it did not accept the connection in time"))
        case let code:
            return .failed(.connectFailed(reason: String(cString: strerror(code))))
        }
    }

    private static func pause(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        var request = timespec(tv_sec: Int(seconds), tv_nsec: Int(attoseconds / 1_000_000_000))
        var remaining = timespec()
        while nanosleep(&request, &remaining) != 0, errno == EINTR {
            request = remaining
        }
    }

    /// Blocking. Reads newline-delimited messages from `input` until the
    /// first request, writes one JSON-RPC error with that id and code
    /// -32000, and returns. Notifications and responses are skipped. A
    /// batch gets that error with id null; an unparseable or oversized line
    /// gets a -32700 parse error with id null. On EOF first, writes nothing.
    static func answerFirstRequest(input: Int32, output: Int32, with reason: BridgeOutcome.Unavailable) {
        var framer = LineFramer()
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            let lines: [Data]
            do {
                lines = try framer.append(buffer[..<count])
            } catch {
                return reply(id: nil, code: .parseError, reason, to: output)
            }
            for line in lines {
                switch JSONRPCMessage.parse(line) {
                case .message(let message) where message.kind == .request:
                    return reply(id: message.id, reason, to: output)
                case .message:
                    continue
                case .batch:
                    return reply(id: nil, reason, to: output)
                case .invalid:
                    return reply(id: nil, code: .parseError, reason, to: output)
                }
            }
        }
    }

    private static func reply(
        id: Any?, code: JSONRPCErrorCode = .serverError, _ reason: BridgeOutcome.Unavailable, to output: Int32
    ) {
        let message = code == .parseError ? "Parse error. \(reason.message)" : reason.message
        _ = writeAll(output, [UInt8](JSONRPC.error(id: id, code: code, message: message)) + [0x0A])
    }
}

/// Whether a user has a desktop (Aqua) login, on screen or switched out.
/// launchd runs the helper only inside one, so with none, nothing a client
/// or SSH session does will start it (088 #6).
enum DesktopLogin {
    /// True when the session list cannot be read, so the bridge falls back
    /// to its usual advice.
    static func isLoggedIn(uid: uid_t = geteuid()) -> Bool {
        guard let store = SCDynamicStoreCreate(nil, "imessage-max-bridge" as CFString, nil, nil) else { return true }
        let value = SCDynamicStoreCopyValue(store, SCDynamicStoreKeyCreateConsoleUser(nil))
        return hasSession(uid: uid, consoleUser: value as? [String: Any])
    }

    /// `consoleUser` is the State:/Users/ConsoleUser entry, which lists every
    /// desktop login under SessionInfo. No entry means no one is logged in.
    static func hasSession(uid: uid_t, consoleUser: [String: Any]?) -> Bool {
        guard let consoleUser else { return false }
        if let sessions = consoleUser["SessionInfo"] as? [[String: Any]] {
            return sessions.contains { ($0["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == uid }
        }
        return (consoleUser["UID"] as? NSNumber)?.uint32Value == uid
    }
}

/// One connection to the helper. The session, the writer and a stdin
/// failure each hold a reference while they use the fd; the last release
/// closes it, so no thread writes to a closed or reused fd.
private final class BridgeConnection: Sendable {
    let fd: Int32
    private let holders = Atomic<Int>(1)

    init(_ socket: consuming OwnedSocket) {
        fd = socket.release()
    }

    func retain() {
        holders.add(1, ordering: .relaxed)
    }

    func release() {
        if holders.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            close(fd)
        }
    }
}

/// One client session across any number of helper connections.
///
/// Three threads: the caller's runs the connections (reads the helper,
/// reconnects), one reads stdin into the outbox, and one writes the outbox
/// to the helper while the session is live. Only the stdin and helper reads
/// parse JSON-RPC, and only to track which requests wait for a reply and
/// which `initialize` to replay.
///
/// While the helper is away, new client messages wait in the outbox, up to
/// `maxQueuedMessages` and `maxQueuedBytes`, and go out in order after the
/// reconnect. A restart takes about the 10 s throttle, and a request that
/// waits for it succeeds, where failing it fast would hand every agent an
/// error to notice and retry. Requests in the queue have not reached any
/// helper, so sending them later never runs anything twice. Past the bound,
/// a request gets a -32000 error at once. Requests the old helper had
/// already received get -32000 at the disconnect and are never resent: a
/// `send` may already have gone out.
private final class BridgeSession: @unchecked Sendable {
    static let maxQueuedMessages = 64
    static let maxQueuedBytes = 4 * 1024 * 1024
    static let lostReplyMessage = "iMessage Max restarted while this request was running, so its reply was lost. Retry the request. Before you retry a send, check the chat with get_messages, because the message may already have gone out."
    static let queueFullMessage = "iMessage Max is restarting, and too many requests are already waiting for it. Retry in a few seconds."

    private enum Phase {
        /// No connection. The outbox waits.
        case down
        /// Connected, the replayed initialize is out, and its reply has not
        /// come back. The outbox waits.
        case replaying
        /// The writer drains the outbox to the helper.
        case live
    }

    private struct Outgoing {
        let line: Data
        /// The request's key and raw id, for a request.
        let request: (key: String, id: Any)?
    }

    private enum PumpEnd {
        case helperClosed
        case stdoutClosed
        case stdoutFailed(String)
    }

    private enum ReconnectFailure: Error {
        case inputEnded
        case inputFailed(String)
        case unavailable(BridgeOutcome.Unavailable)
    }

    private let socket: SocketPath
    private let input: Int32
    private let output: Int32
    private let grace: Duration
    private let hasDesktopLogin: @Sendable () -> Bool
    private let stdoutLock = NSLock()
    private let clock = ContinuousClock()

    /// Guards every field below.
    private let condition = NSCondition()
    private var connection: BridgeConnection?
    private var halfClosed = false
    private var phase = Phase.down
    private var outbox: [Outgoing] = []
    private var outboxBytes = 0
    /// Requests written to the current helper with no reply yet, by key.
    private var inFlight: [String: Any] = [:]
    /// The client's latest initialize, until a successful reply confirms it.
    private var pendingInitialize: (key: String, line: Data)?
    /// The client's last successful initialize, replayed on each reconnect.
    private var initializeLine: Data?
    private var initializedLine: Data?
    private var replayKey: String?
    private var replayCount = 0
    private var replayTimer: DispatchSourceTimer?
    /// A helper accepted the connection and never answered the replay.
    private var replayUnanswered = false
    /// When the session last stopped being live. A reconnect gives up
    /// `grace` after this, however many connections it tried in between.
    private var downSince: ContinuousClock.Instant?
    private var inputEnded = false
    private var inputFailure: String?
    private var stopped = false

    init(
        socket: SocketPath, input: Int32, output: Int32, grace: Duration,
        hasDesktopLogin: @escaping @Sendable () -> Bool
    ) {
        self.socket = socket
        self.input = input
        self.output = output
        self.grace = grace
        self.hasDesktopLogin = hasDesktopLogin
    }

    func run(first: BridgeConnection) -> BridgeOutcome {
        Thread.detachNewThread { [self] in readClient() }
        Thread.detachNewThread { [self] in writeHelper() }
        var current = first
        while true {
            if let replay = begin(current) {
                _ = StdioBridge.writeAll(current.fd, [UInt8](replay) + [0x0A])
            }
            let end = pumpDown(from: current)
            let (orphans, ended, failure) = endConnection(current)
            if let failure { return stop(.ioFailure(failure)) }
            switch end {
            case .stdoutClosed: return stop(.finished)
            case .stdoutFailed(let reason): return stop(.ioFailure(reason))
            case .helperClosed: break
            }
            if ended { return stop(.finished) }

            Log.warning("iMessage Max closed the connection; reconnecting for up to \(String(format: "%g", Self.seconds(grace))) s")
            answer(orphans, message: Self.lostReplyMessage)
            switch reconnect() {
            case .success(let next):
                current = next
            case .failure(.inputEnded):
                return stop(.finished)
            case .failure(.inputFailed(let reason)):
                return stop(.ioFailure(reason))
            case .failure(.unavailable(let reason)):
                Log.error("stdio bridge gave up reconnecting: \(reason.message)")
                answerQueued(reason.message)
                return stop(.helperDisconnected(reason))
            }
        }
    }

    // MARK: Connections

    /// Makes `connection` current. Returns the initialize to replay, with a
    /// bridge-owned id, when the client had a legacy session.
    private func begin(_ connection: BridgeConnection) -> Data? {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        self.connection = connection
        halfClosed = false
        let reconnected = downSince != nil
        guard let initializeLine, var object = try? JSONSerialization.jsonObject(with: initializeLine) as? [String: Any] else {
            if reconnected { Log.info("Reconnected to iMessage Max") }
            phase = .live
            downSince = nil
            return nil
        }
        replayCount += 1
        let id = "imessage-max-bridge-replay-\(replayCount)"
        object["id"] = id
        guard let replay = try? JSONSerialization.data(withJSONObject: object) else {
            phase = .live
            downSince = nil
            return nil
        }
        replayKey = JSONRPCMessage.requestKey(for: id)
        phase = .replaying
        startReplayTimer(for: connection, key: replayKey)
        return replay
    }

    /// A helper that accepts the connection but never answers the replayed
    /// initialize must not hold the queue forever: the connection is cut
    /// once the grace is up, and the reconnect gives up.
    private func startReplayTimer(for connection: BridgeConnection, key: String?) {
        replayTimer?.cancel()
        let remaining = max(clock.now.duration(to: (downSince ?? clock.now) + grace), .milliseconds(500))
        let timer = DispatchSource.makeTimerSource(queue: .global())
        connection.retain()
        timer.schedule(deadline: .now() + .milliseconds(Int(remaining / .milliseconds(1))))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            condition.lock()
            let stale = replayKey == key && self.connection === connection
            if stale { replayUnanswered = true }
            condition.unlock()
            if stale {
                Log.warning("iMessage Max did not answer the replayed initialize; dropping the connection")
                shutdown(connection.fd, SHUT_RDWR)
            }
        }
        timer.setCancelHandler { connection.release() }
        replayTimer = timer
        timer.resume()
    }

    /// Detaches `connection` and returns what the disconnect left: requests
    /// that will get no reply, and whether stdin has ended or failed.
    private func endConnection(_ connection: BridgeConnection) -> (orphans: [Any], ended: Bool, failure: String?) {
        condition.lock()
        self.connection = nil
        phase = .down
        replayKey = nil
        replayTimer?.cancel()
        replayTimer = nil
        if downSince == nil { downSince = clock.now }
        let orphans = Array(inFlight.values)
        inFlight = [:]
        pendingInitialize = nil
        let ended = inputEnded
        let failure = inputFailure
        condition.broadcast()
        condition.unlock()
        // Unblocks the writer if it is mid-write to a helper that stopped reading.
        shutdown(connection.fd, SHUT_RDWR)
        connection.release()
        return (orphans, ended, failure)
    }

    /// Retries until the grace since the session went down is up. Gives up
    /// early when stdin fails, or ends with no request left to deliver.
    private func reconnect() -> Result<BridgeConnection, ReconnectFailure> {
        condition.lock()
        let deadline = (downSince ?? clock.now) + grace
        condition.unlock()
        var interval = StdioBridge.retryIntervals.first
        while true {
            condition.lock()
            let failure = inputFailure
            let ended = inputEndedWithNothingToDeliver
            let unanswered = replayUnanswered
            condition.unlock()
            if let failure { return .failure(.inputFailed(failure)) }
            if ended { return .failure(.inputEnded) }
            if unanswered, clock.now >= deadline {
                return .failure(.unavailable(.connectFailed(reason: "it accepted the connection but did not answer initialize")))
            }

            switch StdioBridge.attempt(socket, deadline: max(deadline, clock.now + .seconds(1))) {
            case .connected(let owned):
                return .success(BridgeConnection(owned))
            case .failed(let reason):
                return .failure(.unavailable(reason))
            case .notListening:
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else {
                    return .failure(.unavailable(StdioBridge.explain(.notRunning, hasDesktopLogin: hasDesktopLogin)))
                }
                wait(min(remaining, interval))
                interval = min(interval * 2, StdioBridge.retryIntervals.last)
            }
        }
    }

    /// Call with the lock held. The client left, and no request of its is
    /// waiting for an answer.
    private var inputEndedWithNothingToDeliver: Bool {
        inputEnded && !outbox.contains { $0.request != nil }
    }

    /// Waits on the condition, so stdin failing, or ending with nothing
    /// left to deliver, cuts the wait short.
    private func wait(_ duration: Duration) {
        let wake = Date(timeIntervalSinceNow: Self.seconds(duration))
        condition.lock()
        while inputFailure == nil, !inputEndedWithNothingToDeliver, condition.wait(until: wake) {}
        condition.unlock()
    }

    private func stop(_ outcome: BridgeOutcome) -> BridgeOutcome {
        condition.lock()
        stopped = true
        connection = nil
        replayTimer?.cancel()
        replayTimer = nil
        condition.broadcast()
        condition.unlock()
        switch outcome {
        case .finished, .helperUnavailable, .helperDisconnected: break
        case .ioFailure(let reason): Log.error("stdio bridge failed: \(reason)")
        }
        return outcome
    }

    // MARK: Helper to client

    private func pumpDown(from connection: BridgeConnection) -> PumpEnd {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: StdioBridge.chunkBytes)
        while true {
            let count = read(connection.fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return .helperClosed }
            var scan = pending.count
            pending.append(contentsOf: buffer[..<count])
            var start = 0
            while let newline = pending[scan...].firstIndex(of: 0x0A) {
                let line = pending.subdata(in: start..<newline)
                start = newline + 1
                scan = start
                guard !line.isEmpty, forwards(line) else { continue }
                let error = emit(line)
                if error == EPIPE { return .stdoutClosed }
                if error != 0 { return .stdoutFailed("write stdout: \(String(cString: strerror(error)))") }
            }
            if start > 0 { pending.removeSubrange(0..<start) }
        }
    }

    /// Settles any request this line answers. False for the reply to a
    /// replayed initialize, which the client never asked for.
    private func forwards(_ line: Data) -> Bool {
        condition.lock()
        let tracking = !inFlight.isEmpty || replayKey != nil
        condition.unlock()
        guard tracking,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["method"] == nil,
              let key = JSONRPCMessage.requestKey(for: object["id"])
        else { return true }
        let succeeded = object["result"] != nil

        condition.lock()
        defer { condition.unlock() }
        if key == replayKey {
            replayKey = nil
            replayTimer?.cancel()
            replayTimer = nil
            if !succeeded { Log.warning("iMessage Max refused the replayed initialize") }
            if let initializedLine {
                outbox.insert(Outgoing(line: initializedLine, request: nil), at: 0)
                outboxBytes += initializedLine.count
            }
            Log.info("Reconnected to iMessage Max; replayed initialize")
            phase = .live
            downSince = nil
            replayUnanswered = false
            condition.broadcast()
            return false
        }
        guard inFlight.removeValue(forKey: key) != nil else { return true }
        if let pending = pendingInitialize, pending.key == key {
            pendingInitialize = nil
            if succeeded { initializeLine = pending.line }
        }
        return true
    }

    /// Writes one line to stdout, whole. Returns 0 or the errno.
    @discardableResult
    private func emit(_ line: Data) -> Int32 {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        return StdioBridge.writeAll(output, [UInt8](line) + [0x0A])
    }

    private func answer(_ ids: [Any], message: String) {
        for id in ids {
            emit(JSONRPC.error(id: id, code: .serverError, message: message))
        }
    }

    private func answerQueued(_ message: String) {
        condition.lock()
        let ids = outbox.compactMap { $0.request?.id }
        outbox = []
        outboxBytes = 0
        condition.broadcast()
        condition.unlock()
        answer(ids, message: message)
    }

    // MARK: Client to helper

    private func readClient() {
        var framer = LineFramer()
        var buffer = [UInt8](repeating: 0, count: StdioBridge.chunkBytes)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count > 0 {
                let lines: [Data]
                do {
                    lines = try framer.append(buffer[..<count])
                } catch {
                    emit(JSONRPC.error(
                        id: nil, code: .parseError,
                        message: "Parse error. A message is over \(LineFramer.maxMessageBytes) bytes."))
                    return fail("read stdin: a message is over \(LineFramer.maxMessageBytes) bytes")
                }
                for line in lines { accept(line) }
            } else if count == 0 {
                condition.lock()
                inputEnded = true
                condition.broadcast()
                condition.unlock()
                return
            } else if errno != EINTR {
                return fail("read stdin: \(String(cString: strerror(errno)))")
            }
        }
    }

    private func fail(_ reason: String) {
        condition.lock()
        inputFailure = reason
        let connection = connection
        connection?.retain()
        condition.broadcast()
        condition.unlock()
        // Ends the helper read, so the session loop sees the failure.
        if let connection {
            shutdown(connection.fd, SHUT_RDWR)
            connection.release()
        }
    }

    private func accept(_ line: Data) {
        var request: (key: String, id: Any)?
        var isInitialize = false
        var isInitialized = false
        if case .message(let message) = JSONRPCMessage.parse(line) {
            if message.kind == .request, let id = message.id, let key = message.requestKey {
                request = (key, id)
                isInitialize = message.isInitialize
            }
            isInitialized = message.kind == .notification && message.method == "notifications/initialized"
        }

        condition.lock()
        if isInitialize, let request { pendingInitialize = (request.key, line) }
        if isInitialized { initializedLine = line }
        while isFull(adding: line), phase == .live, !stopped {
            condition.wait()
        }
        let rejected = isFull(adding: line)
        if !rejected {
            outbox.append(Outgoing(line: line, request: request))
            outboxBytes += line.count
            condition.broadcast()
        }
        condition.unlock()
        // A notification over the bound is dropped; a request is answered.
        if rejected, let request {
            emit(JSONRPC.error(id: request.id, code: .serverError, message: Self.queueFullMessage))
        }
    }

    /// Call with the lock held. An empty outbox always takes one message.
    private func isFull(adding line: Data) -> Bool {
        !outbox.isEmpty && (outbox.count >= Self.maxQueuedMessages || outboxBytes + line.count > Self.maxQueuedBytes)
    }

    private func writeHelper() {
        condition.lock()
        while !stopped {
            guard phase == .live, let connection else {
                condition.wait()
                continue
            }
            if !outbox.isEmpty {
                let item = outbox.removeFirst()
                outboxBytes -= item.line.count
                if let request = item.request { inFlight[request.key] = request.id }
                connection.retain()
                condition.broadcast()
                condition.unlock()
                if StdioBridge.writeAll(connection.fd, [UInt8](item.line) + [0x0A]) != 0 {
                    // The read side sees the end and reconnects.
                    shutdown(connection.fd, SHUT_RDWR)
                }
                connection.release()
                condition.lock()
                continue
            }
            if inputEnded, !halfClosed {
                // Half-close: the helper reads EOF, drains its replies, then closes.
                halfClosed = true
                shutdown(connection.fd, SHUT_WR)
            }
            condition.wait()
        }
        condition.unlock()
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
