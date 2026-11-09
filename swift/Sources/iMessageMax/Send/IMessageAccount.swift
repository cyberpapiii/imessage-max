import Foundation
import IMessageMaxContract
import Synchronization

/// One account as Messages reports it through AppleScript.
struct MessagesAccountRecord: Equatable, Sendable {
    /// The sdef's `service type`: "iMessage", "SMS" or "RCS". "other" when
    /// Messages cannot name it, which some built-in accounts do (-10000).
    let service: String
    let enabled: Bool
    /// The sdef's `connection status`: "connected", "connecting",
    /// "disconnected" or "disconnecting". "unknown" when Messages fails to say.
    let connection: String

    var isConnected: Bool { connection == "connected" }
}

/// Reads Messages' accounts without changing anything. The script asks for
/// three read-only properties of each `account` in the Messages sdef:
/// `service type`, `enabled` and `connection status`. It asks one account at
/// a time, because `service type of every account` fails as a whole (-10000)
/// when any account's type has no name in the sdef.
enum IMessageAccountScript {
    static let accountMarker = "IMESSAGE_MAX_ACCOUNT"
    static let doneMarker = "IMESSAGE_MAX_ACCOUNTS_DONE"

    static let source = """
        on run
            set report to ""
            tell application "Messages"
                set accountCount to count accounts
                repeat with accountIndex from 1 to accountCount
                    set anAccount to account accountIndex
                    set serviceName to "other"
                    set isEnabled to "unknown"
                    set connectionName to "unknown"
                    try
                        set serviceName to (service type of anAccount) as text
                    end try
                    try
                        set isEnabled to (enabled of anAccount) as text
                    end try
                    try
                        set connectionName to (connection status of anAccount) as text
                    end try
                    set report to report & "\(accountMarker)" & tab & serviceName & tab & isEnabled & tab & connectionName & linefeed
                end repeat
            end tell
            return report & "\(doneMarker)" & tab & accountCount
        end run
        """

    /// The accounts the script listed, or nil when its output is not a whole
    /// report.
    static func parse(_ stdout: String) -> [MessagesAccountRecord]? {
        var accounts: [MessagesAccountRecord] = []
        var expected: Int?
        for line in stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case accountMarker? where fields.count == 4:
                accounts.append(MessagesAccountRecord(
                    service: fields[1], enabled: fields[2] == "true", connection: fields[3]))
            case doneMarker? where fields.count == 2:
                expected = Int(fields[1].trimmingCharacters(in: .whitespaces))
            default:
                continue
            }
        }
        guard let expected, expected == accounts.count else { return nil }
        return accounts
    }

    /// What the accounts mean for sending.
    ///
    /// SMS on a Mac goes through a paired iPhone (Text Message Forwarding),
    /// which Apple ties to iMessage being signed in with the same Apple
    /// Account. So a Mac with no iMessage account on but a connected SMS
    /// account is rare. When Messages does report one, the send script uses
    /// it for phone numbers, and this reports `sms_only` rather than broken.
    static func status(of accounts: [MessagesAccountRecord]) -> IMessageAccountStatus {
        let iMessage = accounts.filter { $0.service == "iMessage" }
        let enabled = iMessage.filter(\.enabled)
        if enabled.contains(where: \.isConnected) { return .signedIn }
        if enabled.contains(where: { $0.connection == "connecting" }) { return .connecting }
        if !enabled.isEmpty { return .signedOut }
        if accounts.contains(where: { $0.service == "SMS" && $0.enabled && $0.isConnected }) { return .smsOnly }
        return iMessage.isEmpty ? .noAccount : .disabled
    }
}

/// Answers "can Messages send iMessages?" for diagnose. The answer costs an
/// osascript run, so a definite one is kept for `cacheLifetime`. A caller
/// waits at most `timeout`; a read that takes longer goes on in the
/// background, and its answer is kept for the next caller. Only one read
/// runs at a time.
///
/// Messages is started (hidden) for the check only until the helper has read
/// the account once. After that, a Messages that someone quit stays closed
/// and the check reports `messages_not_running`: diagnose is polled, and a
/// poll must not keep bringing Messages back.
final class IMessageAccountMonitor: Sendable {
    typealias Read = @Sendable (_ mayStartMessages: Bool) -> IMessageAccountStatus
    typealias Clock = @Sendable () -> ContinuousClock.Instant

    static let timeout: DispatchTimeInterval = .seconds(2)
    static let cacheLifetime: Duration = .seconds(60)

    /// Answers about the account itself. The rest (still connecting, or the
    /// check could not run) are read again on the next call.
    static let definite: Set<IMessageAccountStatus> = [.signedIn, .signedOut, .disabled, .noAccount, .smsOnly]

    private final class Flight: Sendable {
        let done = DispatchGroup()
        let answer = Mutex<IMessageAccountStatus?>(nil)
    }

    private struct State {
        var kept: (status: IMessageAccountStatus, at: ContinuousClock.Instant)?
        var flight: Flight?
        var hasRead = false
    }

    private let read: Read
    private let timeout: DispatchTimeInterval
    private let cacheLifetime: Duration
    private let now: Clock
    private let state = Mutex(State())

    init(
        timeout: DispatchTimeInterval = IMessageAccountMonitor.timeout,
        cacheLifetime: Duration = IMessageAccountMonitor.cacheLifetime,
        now: @escaping Clock = { ContinuousClock.now },
        read: @escaping Read
    ) {
        self.read = read
        self.timeout = timeout
        self.cacheLifetime = cacheLifetime
        self.now = now
    }

    /// Blocks for at most `timeout`, so call it off the cooperative pool.
    func status() -> IMessageAccountStatus {
        let current = now()
        enum Next { case kept(IMessageAccountStatus), wait(Flight), start(Flight, mayStart: Bool) }
        let next: Next = state.withLock { state in
            if let kept = state.kept, current - kept.at < cacheLifetime { return .kept(kept.status) }
            if let flight = state.flight { return .wait(flight) }
            let flight = Flight()
            flight.done.enter()
            state.flight = flight
            return .start(flight, mayStart: !state.hasRead)
        }

        let flight: Flight
        switch next {
        case .kept(let status):
            return status
        case .wait(let running):
            flight = running
        case .start(let started, let mayStart):
            flight = started
            let thread = Thread { [self] in finish(started, with: read(mayStart)) }
            thread.name = "imessage-max.account-probe"
            thread.start()
        }

        guard flight.done.wait(timeout: .now() + timeout) == .success,
              let answer = flight.answer.withLock({ $0 })
        else { return .messagesNotResponding }
        return answer
    }

    /// The last definite answer, while it is fresh. Never runs a check.
    var keptStatus: IMessageAccountStatus? {
        let current = now()
        return state.withLock { state in
            guard let kept = state.kept, current - kept.at < cacheLifetime else { return nil }
            return kept.status
        }
    }

    private func finish(_ flight: Flight, with answer: IMessageAccountStatus) {
        flight.answer.withLock { $0 = answer }
        let previous: IMessageAccountStatus? = state.withLock { state in
            let previous = state.kept?.status
            state.flight = nil
            if Self.definite.contains(answer) {
                state.kept = (answer, now())
                state.hasRead = true
            }
            return previous
        }
        if Self.definite.contains(answer), answer != previous {
            if answer == .signedIn {
                Log.info("iMessage account: \(answer.rawValue)")
            } else {
                Log.warning("iMessage account: \(answer.rawValue)")
            }
        }
        flight.done.leave()
    }

    /// The real check: starts Messages hidden when allowed, then runs the
    /// read-only account script through the osascript gate.
    static func liveRead(
        launch: @escaping MessagesAccess.Launch,
        isRunning: @escaping @Sendable () -> Bool = { MessagesLauncher.isRunning },
        runScript: @escaping ScriptExecutor = { ScriptGate.shared.run($0, arguments: $1) }
    ) -> Read {
        { mayStartMessages in
            if !mayStartMessages, !isRunning() { return .messagesNotRunning }
            // Started by osascript itself, Messages would show its window.
            guard launch("the iMessage account check") else { return .messagesNotResponding }
            switch runScript(IMessageAccountScript.source, []) {
            case .failure(.timeout), .failure(.messagesAppUnavailable):
                return .messagesNotResponding
            case .failure:
                return .checkFailed
            case .success(let output):
                guard output.terminationStatus == 0, let accounts = IMessageAccountScript.parse(output.stdout) else {
                    let line = Osascript.clientSafeFirstLine(output.stderr, logLabel: "account check stderr") ?? ""
                    Log.warning("iMessage account check failed: \(line)")
                    return .checkFailed
                }
                return IMessageAccountScript.status(of: accounts)
            }
        }
    }
}
