import Darwin
import Foundation
import Synchronization

/// How a bridge run ended. One exit code per case, and one client-facing
/// message for each way the bridge never reached a helper.
enum BridgeOutcome: Equatable, Sendable {
    /// The client closed stdin and the helper drained and closed, or the
    /// client stopped reading stdout.
    case finished
    /// Never connected. The first request on stdin got a JSON-RPC error.
    case helperUnavailable(Unavailable)
    /// The helper closed while the client was still sending (helper
    /// restart, crash, or helper SIGTERM).
    case helperDisconnected
    /// A read or write failed for a reason other than the peer leaving.
    case ioFailure(String)

    enum Unavailable: Error, Equatable, Sendable {
        /// Nothing listens on the socket once the grace has passed.
        case notRunning
        /// The process serving the socket runs as another user.
        case foreignPeer(uid: uid_t)
        /// The socket's folder is not a folder you own.
        case unsafeFolder(path: String)
        case connectFailed(reason: String)

        var message: String {
            switch self {
            case .notRunning:
                "iMessage Max is not running. Open iMessage Max to start it."
            case .foreignPeer(let uid):
                "The iMessage Max socket is served by another user (uid \(uid)). Open iMessage Max in your own account to start it."
            case .unsafeFolder(let path):
                "Folder \(path) belongs to another user, or is not a folder. Pass --socket-path with a path in a folder you own."
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

/// Copies stdio bytes to and from the helper's socket so a client-spawned
/// process never needs Full Disk Access, Contacts or Automation itself.
enum StdioBridge {
    /// Long enough to cover a login race, where the client starts before
    /// launchd has the helper listening.
    static let defaultConnectGrace: Duration = .seconds(3)
    private static let retryInterval: Duration = .milliseconds(100)
    private static let chunkBytes = 64 * 1024

    /// Copies `input` to the helper's socket and the socket to `output`
    /// until one side ends. Never parses JSON-RPC except to answer the
    /// first request when no helper is reachable. Never closes `input` or
    /// `output`; the caller owns them.
    ///
    /// Runs on its own threads, so no cooperative thread blocks.
    static func run(
        socket: SocketPath,
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        connectGrace: Duration = defaultConnectGrace
    ) async -> BridgeOutcome {
        await withCheckedContinuation { done in
            Thread.detachNewThread {
                done.resume(returning: runBlocking(socket: socket, input: input, output: output, connectGrace: connectGrace))
            }
        }
    }

    private static func runBlocking(socket: SocketPath, input: Int32, output: Int32, connectGrace: Duration) -> BridgeOutcome {
        let connected: OwnedSocket
        switch connect(socket, grace: connectGrace) {
        case .failure(let reason):
            Log.error(reason.message)
            answerFirstRequest(input: input, output: output, with: reason)
            return .helperUnavailable(reason)
        case .success(let owned):
            connected = owned
        }
        let shared = SharedSocket(connected)

        Thread.detachNewThread {
            pumpUp(from: input, to: shared)
        }
        let outcome = pumpDown(from: shared, to: output)
        // Unblocks the up pump if it is mid-write to a helper that stopped reading.
        shutdown(shared.fd, SHUT_RDWR)
        shared.release()

        switch outcome {
        case .finished, .helperUnavailable: break
        case .helperDisconnected: Log.warning("iMessage Max closed the connection")
        case .ioFailure(let reason): Log.error("stdio bridge failed: \(reason)")
        }
        return outcome
    }

    private static func pumpUp(from input: Int32, to socket: SharedSocket) {
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count > 0 {
                if writeAll(socket.fd, buffer, count: count) != 0 { break }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                socket.inputEnded.store(true, ordering: .sequentiallyConsistent)
                break
            }
        }
        // Half-close: the helper reads EOF, drains its replies, then closes.
        shutdown(socket.fd, SHUT_WR)
        socket.release()
    }

    private static func pumpDown(from socket: SharedSocket, to output: Int32) -> BridgeOutcome {
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        while true {
            let count = read(socket.fd, &buffer, buffer.count)
            if count > 0 {
                let error = writeAll(output, buffer, count: count)
                if error == EPIPE { return .finished }
                if error != 0 { return .ioFailure("write stdout: \(String(cString: strerror(error)))") }
                continue
            }
            if count < 0 {
                let error = errno
                if error == EINTR { continue }
                if error != ECONNRESET { return .ioFailure("read socket: \(String(cString: strerror(error)))") }
            }
            return socket.inputEnded.load(ordering: .sequentiallyConsistent) ? .finished : .helperDisconnected
        }
    }

    /// Returns 0 or the errno of the failed write.
    private static func writeAll(_ fd: Int32, _ buffer: [UInt8], count: Int) -> Int32 {
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes { write(fd, $0.baseAddress! + offset, count - offset) }
            if written < 0 {
                if errno == EINTR { continue }
                return errno
            }
            offset += written
        }
        return 0
    }

    /// Blocking. Retries a missing socket or folder, and a refused connect,
    /// every 100 ms until `grace` passes. Checks the folder with
    /// PrivateFolder.requireOwned and never creates it. Checks the
    /// server's uid after connecting.
    static func connect(_ socket: SocketPath, grace: Duration) -> Result<OwnedSocket, BridgeOutcome.Unavailable> {
        let clock = ContinuousClock()
        let deadline = clock.now + grace
        while true {
            switch attempt(socket) {
            case .connected(let owned):
                return .success(owned)
            case .failed(let reason):
                return .failure(reason)
            case .notListening:
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { return .failure(.notRunning) }
                pause(min(remaining, retryInterval))
            }
        }
    }

    private enum Attempt: ~Copyable {
        case connected(OwnedSocket)
        case notListening
        case failed(BridgeOutcome.Unavailable)
    }

    private static func attempt(_ socket: SocketPath) -> Attempt {
        do {
            try PrivateFolder.requireOwned(socket.folder)
        } catch .missing {
            return .notListening
        } catch .notOwnedFolder(let path) {
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
        switch owned.connect(to: socket) {
        case 0:
            guard let uid = owned.peerUID() else {
                return .failed(.connectFailed(reason: "cannot read the server's user id"))
            }
            guard uid == geteuid() else { return .failed(.foreignPeer(uid: uid)) }
            return .connected(owned)
        case ENOENT, ECONNREFUSED:
            return .notListening
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
    /// batch or an unparseable line gets the error with id null. On EOF
    /// first, writes nothing.
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
                return reply(id: nil, reason, to: output)
            }
            for line in lines {
                switch JSONRPCMessage.parse(line) {
                case .message(let message) where message.kind == .request:
                    return reply(id: message.id, reason, to: output)
                case .message:
                    continue
                case .batch, .invalid:
                    return reply(id: nil, reason, to: output)
                }
            }
        }
    }

    private static func reply(id: Any?, _ reason: BridgeOutcome.Unavailable, to output: Int32) {
        var bytes = [UInt8](JSONRPC.error(id: id, code: .serverError, message: reason.message))
        bytes.append(0x0A)
        _ = writeAll(output, bytes, count: bytes.count)
    }
}

/// The connected socket, shared by the two pumps. The second release closes
/// it, so neither pump can close an fd the other is still using.
private final class SharedSocket: Sendable {
    let fd: Int32
    let inputEnded = Atomic<Bool>(false)
    private let holders = Atomic<Int>(2)

    init(_ socket: consuming OwnedSocket) {
        fd = socket.release()
    }

    func release() {
        if holders.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            close(fd)
        }
    }
}
