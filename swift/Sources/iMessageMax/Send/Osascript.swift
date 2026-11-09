import Foundation

enum Osascript {
    struct Output {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    private static let timeout: DispatchTimeInterval = .seconds(30)

    static func run(_ script: String, arguments: [String]) -> Result<Output, SendError> {
        // Process.run raises an Objective-C exception, which Swift cannot
        // catch, for an argument holding NUL, and that aborts the helper.
        // SendPayload.build rejects NUL first; this keeps any other caller safe.
        guard !containsNUL(script), !arguments.contains(where: containsNUL) else {
            return .failure(.invalidParams(nulRejection))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + (arguments.isEmpty ? [] : ["--"] + arguments)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // The exit handler signals instead of a thread parked in
        // waitUntilExit, so a run costs no thread while the script works.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()

            // Drain both pipes while waiting for exit. If the reads wait until
            // exit, a child that fills the ~64KB pipe buffer blocks on write and
            // never exits, so the wait times out.
            final class DrainedOutput: @unchecked Sendable {
                var stdout = Data()
                var stderr = Data()
            }
            let drained = DrainedOutput()
            let drainGroup = DispatchGroup()

            drainGroup.enter()
            DispatchQueue.global().async {
                drained.stdout = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                drainGroup.leave()
            }
            drainGroup.enter()
            DispatchQueue.global().async {
                drained.stderr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                drainGroup.leave()
            }

            if exited.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
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

    static let nulRejection = "Text, file paths and recipients cannot contain a NUL character (U+0000)."

    static func containsNUL(_ value: String) -> Bool {
        value.utf8.contains(0)
    }

    /// AppleScript writes "can’t" and other contractions with U+2019.
    static func normalizingApostrophes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static let privatePathMarkers = ["/users/", "/private/", "/var/", OutgoingFileStager.directoryName]

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
