import Foundation

/// Runs one AppleScript through /usr/bin/osascript and handles its
/// untrusted stderr. Blocks the calling thread for up to `timeout`.
enum Osascript {
    struct Output {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    private static let timeout: DispatchTimeInterval = .seconds(30)

    /// Fails with `.timeout` when osascript outlives `timeout`, or `.failed`
    /// when it could not be launched at all.
    static func run(_ script: String, arguments: [String]) -> Result<Output, SendError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + (arguments.isEmpty ? [] : ["--"] + arguments)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()

            // Drain pipes concurrently with the exit wait. Reading only after
            // exit deadlocks when the child fills a ~64KB pipe buffer: the
            // child blocks on write, never exits, and the wait times out.
            // Each queue writes its own property and the group join below
            // establishes the happens-before edge for the reads.
            final class DrainedOutput: @unchecked Sendable {
                var stdout = Data()
                var stderr = Data()
            }
            let drained = DrainedOutput()
            let drainGroup = DispatchGroup()

            drainGroup.enter()
            DispatchQueue.global().async {
                drained.stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                drainGroup.leave()
            }
            drainGroup.enter()
            DispatchQueue.global().async {
                drained.stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                drainGroup.leave()
            }

            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                process.waitUntilExit()
                semaphore.signal()
            }

            if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                // Give SIGTERM a moment, then SIGKILL so the pipes close and the
                // drain threads can exit. osascript ignores SIGTERM while blocked
                // in a Messages Apple event; without this the readers block on an
                // open pipe forever, one pair per timed-out send.
                if drainGroup.wait(timeout: .now() + .seconds(2)) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = drainGroup.wait(timeout: .now() + .seconds(2))
                }
                return .failure(.timeout)
            }
            drainGroup.wait()

            return .success(Output(
                stdout: String(data: drained.stdout, encoding: .utf8) ?? "",
                stderr: String(data: drained.stderr, encoding: .utf8) ?? "",
                terminationStatus: process.terminationStatus
            ))
        } catch {
            return .failure(.failed(ClientErrorMessages.internalDetail(error, context: "Running AppleScript")))
        }
    }

    /// AppleScript spells "can’t" and friends with U+2019.
    static func normalizingApostrophes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// Path fragments that must never reach a client: the operator's home
    /// directory, temp directories, and the private staged attachment copy.
    /// Lowercase, because matching runs on a lowercased copy so a mixed-case
    /// "/Users/" still scrubs.
    private static let privatePathMarkers = ["/users/", "/private/", "/var/", OutgoingFileStager.directoryName]

    /// Untrusted, unbounded osascript stderr reduced to its first line,
    /// clamped to 300 characters with apostrophes normalized. Nil when that
    /// line names a private path; the line then goes to the server log under
    /// `logLabel` instead. The returned line keeps its original casing so
    /// AppleScript error text stays readable.
    static func clientSafeFirstLine(_ raw: String, logLabel: String) -> String? {
        let firstLine = String(
            (normalizingApostrophes(raw).split(separator: "\n", maxSplits: 1).first ?? "").prefix(300)
        )
        let lowered = firstLine.lowercased()
        if privatePathMarkers.contains(where: { lowered.contains($0) }) {
            Log.error("\(logLabel): \(firstLine)")
            return nil
        }
        return firstLine
    }
}
