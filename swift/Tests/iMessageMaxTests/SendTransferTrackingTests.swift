import XCTest
import Synchronization
@testable import iMessageMax

/// 088 #23: two file sends with the same name read each other's transfer
/// status, because Messages finds transfers by name only. Messages is a fake
/// here: nothing is sent and no script runs.
final class SendTransferTrackingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        // /private form: the stager refuses a root behind the /var symlink.
        let tmp = try XCTUnwrap(SecurePath.absoluteLexicalPath(FileManager.default.temporaryDirectory.path))
        folder = URL(fileURLWithPath: tmp, isDirectory: true)
            .appendingPathComponent("imax-transfers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func source(_ directory: String, _ name: String) throws -> String {
        let dir = folder.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try Data(directory.utf8).write(to: file)
        return file.path
    }

    private func runner(_ messages: FakeTransfers) -> LiveScriptRunner {
        LiveScriptRunner(
            access: makeTestMessagesAccess(),
            stager: OutgoingFileStager(root: folder.appendingPathComponent("staging", isDirectory: true)),
            runScript: { messages.run($0, $1) })
    }

    /// The first send's dispatch waits for the other send to snapshot the
    /// transfers, which is the interleaving that made both read both
    /// transfers. Each send must report its own transfer.
    func testConcurrentSendsOfTheSameNameReadTheirOwnTransfers() async throws {
        let messages = FakeTransfers(
            existing: [("old", "failed")],
            statusByRecipient: ["+15550000001": "failed", "+15550000002": "finished"])
        let runner = runner(messages)
        let pathA = try source("a", "photo.jpg")
        let pathB = try source("b", "Photo.jpg")

        async let a = runner.send(.file(path: pathA), to: .participant(handle: "+15550000001", chatId: nil))
        async let b = runner.send(.file(path: pathB), to: .participant(handle: "+15550000002", chatId: nil))
        let (resultA, resultB) = await (a, b)

        guard case .failure(let failure) = resultA, case .transferFailed = failure.error else {
            return XCTFail("A's transfer failed, got \(resultA)")
        }
        guard case .success = resultB else {
            return XCTFail("B's transfer finished; another transfer's failure is not B's, got \(resultB)")
        }
        XCTAssertEqual(Set(messages.statusQueries), ["t1", "t2"], "each send polls only the transfer it created")
    }

    /// An earlier failed transfer of the same name is not this send's.
    func testEarlierTransferOfTheSameNameIsIgnored() throws {
        let messages = FakeTransfers(
            existing: [("old", "failed")],
            statusByRecipient: ["+15550000001": "finished"])
        let result = runner(messages).sendBlocking(
            .file(path: try source("a", "photo.jpg")), to: .participant(handle: "+15550000001", chatId: nil))
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(messages.statusQueries, ["t1"])
    }

    func testNoNewTransferByTheDeadlineFindsNone() throws {
        let messages = FakeTransfers(existing: [("old", "finished")], statusByRecipient: [:])
        let deadline = Date().addingTimeInterval(0.2)
        let ids = try TransferMonitor.newTransferIds(
            named: "photo.jpg", excluding: ["old"], until: deadline,
            idQuery: { try TransferMonitor.outgoingTransferIds(named: $0, runScript: { messages.run($0, $1) }) },
            pause: { _ in })
        XCTAssertEqual(ids, [])
    }

    func testTransferIdsAreReadOnePerLine() throws {
        let ids = try TransferMonitor.outgoingTransferIds(named: "x", runScript: { _, _ in
            .success(Osascript.Output(stdout: "id, with comma\nsecond\n\n", stderr: "", terminationStatus: 0))
        })
        XCTAssertEqual(ids, ["id, with comma", "second"])
    }

    func testSameNameLockIgnoresCase() {
        XCTAssertEqual(TransferMonitor.lockKey("Photo.JPG"), TransferMonitor.lockKey("photo.jpg"))
    }
}

/// Messages' outgoing file transfers. A send adds one, with the status
/// given for its recipient.
private final class FakeTransfers: Sendable {
    private struct State {
        var transfers: [(id: String, status: String)]
        var idQueries = 0
        var dispatches = 0
        var created = 0
        var statusQueries: [String] = []
    }

    private let state: Mutex<State>
    private let statusByRecipient: [String: String]

    init(existing: [(String, String)], statusByRecipient: [String: String]) {
        state = Mutex(State(transfers: existing.map { (id: $0.0, status: $0.1) }))
        self.statusByRecipient = statusByRecipient
    }

    var statusQueries: [String] { state.withLock { $0.statusQueries } }

    func run(_ script: String, _ arguments: [String]) -> Result<Osascript.Output, SendError> {
        if script == TransferMonitor.idsForNameScript {
            let ids = state.withLock { state in
                state.idQueries += 1
                return state.transfers.map(\.id)
            }
            return output(ids.joined(separator: "\n"))
        }
        if script == TransferMonitor.statusForIdScript {
            let id = arguments[0]
            let status = state.withLock { state in
                state.statusQueries.append(id)
                return state.transfers.first { $0.id == id }?.status ?? ""
            }
            return output(status)
        }
        return dispatch(to: arguments[0])
    }

    private func dispatch(to recipient: String) -> Result<Osascript.Output, SendError> {
        let (isFirst, queriesBefore) = state.withLock { state in
            state.dispatches += 1
            return (state.dispatches == 1, state.idQueries)
        }
        if isFirst {
            // Give the other send up to 0.5 s to take its snapshot now. With
            // the name lock it cannot, and this just waits out the time.
            for _ in 0..<50 where state.withLock({ $0.idQueries }) == queriesBefore {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        state.withLock { state in
            state.created += 1
            state.transfers.append((id: "t\(state.created)", status: statusByRecipient[recipient] ?? ""))
        }
        return output([SendScript.resultMarker, "ok", "completed", "0", ""].joined(separator: "\t"))
    }

    private func output(_ stdout: String) -> Result<Osascript.Output, SendError> {
        .success(Osascript.Output(stdout: stdout, stderr: "", terminationStatus: 0))
    }
}
