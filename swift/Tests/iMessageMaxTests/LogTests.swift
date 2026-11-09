import Synchronization
import XCTest
@testable import iMessageMax

final class LogTests: XCTestCase {
    func testFormatIsStable() {
        let epoch = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            Log.format(.info, "Database: ok", at: epoch),
            "1970-01-01T00:00:00.000Z [imessage-max] INFO Database: ok\n"
        )
        XCTAssertEqual(
            Log.format(.warning, "Binding to '0.0.0.0'", at: epoch),
            "1970-01-01T00:00:00.000Z [imessage-max] WARN Binding to '0.0.0.0'\n"
        )
        XCTAssertEqual(
            Log.format(.error, "session Server.start failed: boom", at: epoch),
            "1970-01-01T00:00:00.000Z [imessage-max] ERROR session Server.start failed: boom\n"
        )
        XCTAssertEqual(
            Log.format(.info, "Database: ok", at: Date(timeIntervalSince1970: 1_790_000_000.25)),
            "2026-09-21T14:13:20.250Z [imessage-max] INFO Database: ok\n"
        )
    }

    private func temporaryDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-redirect-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Restores this process's stderr after a test points it at a file.
    /// The returned function restores it early, so XCTest's failure lines
    /// reach the console instead of the test's log file.
    @discardableResult
    private func keepStandardError() -> () -> Void {
        let saved = dup(STDERR_FILENO)
        addTeardownBlock {
            dup2(saved, STDERR_FILENO)
            close(saved)
        }
        return { _ = dup2(saved, STDERR_FILENO) }
    }

    /// Waits for `condition`, polling. The deadline only guards against a
    /// hang; no assertion depends on how long the wait takes.
    private func waitUntil(_ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting until \(what)")
                throw CancellationError()
            }
            usleep(100)
        }
    }

    /// True once a rotation has finished: `previous` exists and stderr is
    /// the file now at `file`. dup2 is the rotation's last step, so this
    /// never sees one half done, unlike `previous` existing alone.
    private func rotationFinished(_ file: URL, into previous: URL) -> Bool {
        var current = stat()
        var named = stat()
        return FileManager.default.fileExists(atPath: previous.path)
            && fstat(STDERR_FILENO, &current) == 0
            && stat(file.path, &named) == 0
            && current.st_ino == named.st_ino && current.st_dev == named.st_dev
    }

    /// Writes `line` to stderr on its own thread until stopped.
    private final class LineWriter: Sendable {
        let line: String
        private let state = Mutex((written: 0, stop: false))
        private let finished = DispatchSemaphore(value: 0)

        init(line: String) { self.line = line }

        var written: Int { state.withLock { $0.written } }

        func start() {
            Thread { [self] in
                while !state.withLock({ $0.stop }) {
                    Log.writeLine(line, to: STDERR_FILENO)
                    state.withLock { $0.written += 1 }
                }
                finished.signal()
            }.start()
        }

        /// Returns the number of lines written, once the thread has stopped.
        func stop() -> Int {
            state.withLock { $0.stop = true }
            finished.wait()
            return written
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testRedirectAppendsStandardErrorToANewDirectory() throws {
        keepStandardError()
        let file = temporaryDirectory().appendingPathComponent("iMessage Max/imessage-max.log")
        Log.redirectStandardError(to: file.path)
        FileHandle.standardError.write(Data("first\n".utf8))
        Log.redirectStandardError(to: file.path)
        FileHandle.standardError.write(Data("second\n".utf8))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first\nsecond\n")
        XCTAssertEqual(try permissions(file), 0o600)
    }

    func testAnOlderReadableLogBecomesPrivate() throws {
        keepStandardError()
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("imessage-max.log")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: file.path, contents: Data("old\n".utf8), attributes: [.posixPermissions: 0o644]))
        Log.redirectStandardError(to: file.path)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old\n")
    }

    func testALargeLogMovesAsideOnStart() throws {
        keepStandardError()
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("imessage-max.log")
        let previous = dir.appendingPathComponent("imessage-max.log.1")
        try Data("an older rotation\n".utf8).write(to: previous)
        try Data("more than ten bytes\n".utf8).write(to: file)

        Log.redirectStandardError(to: file.path, rotateAbove: 10)
        FileHandle.standardError.write(Data("fresh\n".utf8))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "fresh\n")
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "more than ten bytes\n")

        Log.redirectStandardError(to: file.path, rotateAbove: 10)
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "more than ten bytes\n",
                       "a log under the limit stays where it is")
    }

    /// 088 #31: the log rotated only at startup.
    func testALogThatGrowsWhileRunningMovesAside() throws {
        keepStandardError()
        let dir = temporaryDirectory()
        let file = dir.appendingPathComponent("imessage-max.log")
        let previous = dir.appendingPathComponent("imessage-max.log.1")
        Log.redirectStandardError(to: file.path, rotateAbove: 64)

        Log.writeLine("short\n", to: STDERR_FILENO)
        Log.rotateIfNeeded(file.path, above: 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path), "a log under the limit stays")

        Log.writeLine(String(repeating: "a", count: 100) + "\n", to: STDERR_FILENO)
        Log.rotateIfNeeded(file.path, above: 64)
        Log.writeLine("after\n", to: STDERR_FILENO)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after\n")
        XCTAssertEqual(
            try String(contentsOf: previous, encoding: .utf8),
            "short\n" + String(repeating: "a", count: 100) + "\n")
        XCTAssertEqual(try permissions(file), 0o600)
    }

    func testADeletedLogIsPutBack() throws {
        keepStandardError()
        let file = temporaryDirectory().appendingPathComponent("imessage-max.log")
        Log.redirectStandardError(to: file.path)
        Log.writeLine("before\n", to: STDERR_FILENO)
        try FileManager.default.removeItem(at: file)

        Log.rotateIfNeeded(file.path, above: Log.rotationThreshold)
        Log.writeLine("after\n", to: STDERR_FILENO)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after\n")
    }

    /// 088 #31: the timer, not a test call, starts the check.
    func testTheRotationTimerRotates() throws {
        let restoreStandardError = keepStandardError()
        addTeardownBlock { Log.stopRotating() }
        let dir = temporaryDirectory()
        let file = dir.appendingPathComponent("imessage-max.log")
        let previous = dir.appendingPathComponent("imessage-max.log.1")
        let token = UUID().uuidString
        Log.redirectStandardError(to: file.path, rotateAbove: 64)
        Log.writeLine("before-\(token)" + String(repeating: "a", count: 100) + "\n", to: STDERR_FILENO)

        Log.rotatePeriodically(file.path, above: 64, every: .milliseconds(1))
        try waitUntil("the timer rotates") { rotationFinished(file, into: previous) }
        Log.stopRotating()
        Log.writeLine("after-\(token)\n", to: STDERR_FILENO)
        restoreStandardError()

        let rotated = try String(contentsOf: previous, encoding: .utf8)
        let current = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(rotated.contains("before-\(token)"), rotated)
        XCTAssertTrue(current.contains("after-\(token)"), current)
        XCTAssertFalse(current.contains("before-\(token)"), current)
    }

    /// A rotation while another thread writes loses no line and splits none
    /// across the two files. Darwin's dup2 failed writes with EBADF during
    /// the swap until `standardErrorSwap` covered it. The test fires the
    /// check itself, so exactly one rotation runs, while the writer is busy.
    func testARotationWhileWritingLosesAndSplitsNoLine() throws {
        let restoreStandardError = keepStandardError()
        addTeardownBlock { Log.stopRotating() }
        let dir = temporaryDirectory()
        let file = dir.appendingPathComponent("imessage-max.log")
        let previous = dir.appendingPathComponent("imessage-max.log.1")
        Log.redirectStandardError(to: file.path, rotateAbove: 4096)
        let trigger = DispatchSource.makeUserDataAddSource(queue: DispatchQueue(label: "log-rotation-test"))
        Log.rotate(file.path, above: 4096, whenever: trigger)

        let token = "line-\(UUID().uuidString)"
        let line = token + String(repeating: "x", count: 60) + "\n"
        let writer = LineWriter(line: line)
        writer.start()
        try waitUntil("the log passes the threshold") { writer.written * line.utf8.count > 4096 }
        trigger.add(data: 1)
        try waitUntil("the rotation finishes") { rotationFinished(file, into: previous) }
        let writtenAtRotation = writer.written
        try waitUntil("lines reach the new file") { writer.written >= writtenAtRotation + 50 }
        let written = writer.stop()
        Log.stopRotating()
        restoreStandardError()

        func ours(_ url: URL) throws -> [Substring] {
            try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n").filter { $0.contains(token) }
        }
        let before = try ours(previous)
        let after = try ours(file)
        XCTAssertGreaterThan(before.count * line.utf8.count, 4096, "the lines before the rotation moved aside")
        XCTAssertGreaterThanOrEqual(after.count, 50, "the lines after the rotation went to the new file")
        XCTAssertEqual(before.count + after.count, written, "no line was lost (\(before.count) moved aside, \(after.count) after)")
        XCTAssertTrue((before + after).allSatisfy { $0 == line.dropLast() }, "no line was split")
    }

    func testAnUnopenableLogKeepsStandardErrorAndSaysWhy() throws {
        keepStandardError()
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        var before = stat()
        XCTAssertEqual(fstat(STDERR_FILENO, &before), 0)

        let capture = Log.Capture()
        Log.$capture.withValue(capture) {
            Log.redirectStandardError(to: blocker.appendingPathComponent("imessage-max.log").path)
        }

        var after = stat()
        XCTAssertEqual(fstat(STDERR_FILENO, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_dev, after.st_dev)
        XCTAssertEqual(capture.lines.count, 1)
        XCTAssertTrue(capture.lines.first?.contains("logging stays on stderr") == true, "\(capture.lines)")
    }

    /// A failed write used to raise an Objective-C exception and abort the
    /// helper (088 #1). Each of these must return and drop the line.
    func testWriteLineToAClosedDescriptorReturns() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        close(fds[0])
        close(fds[1])
        Log.writeLine("dropped\n", to: fds[1])
    }

    func testWriteLineToAPipeWithNoReaderReturns() {
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        close(fds[0])
        defer { close(fds[1]) }
        Log.writeLine("dropped\n", to: fds[1])
    }

    func testWriteLineToAReadOnlyDescriptorReturns() throws {
        let file = temporaryDirectory().appendingPathComponent("read-only.log")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
        let fd = open(file.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        Log.writeLine("dropped\n", to: fd)
        XCTAssertEqual(try Data(contentsOf: file).count, 0)
    }

    func testWriteLineWritesEveryByte() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let line = String(repeating: "é", count: 1000) + "\n"
        Log.writeLine(line, to: fds[1])
        close(fds[1])
        let read = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        XCTAssertEqual(String(data: try XCTUnwrap(read.readToEnd()), encoding: .utf8), line)
    }

    func testLogWritesThroughToStandardError() throws {
        keepStandardError()
        let file = temporaryDirectory().appendingPathComponent("stderr.log")
        Log.redirectStandardError(to: file.path)
        Log.info("hello")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasSuffix("INFO hello\n"))
    }
}
