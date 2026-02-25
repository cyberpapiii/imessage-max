// Sources/iMessageMax/Tools/Update.swift
import Foundation
import MCP

// MARK: - Update Response Types

struct UpdateResult: Codable {
    let status: String
    let currentVersion: String
    var previousVersion: String?
    var newVersion: String?
    let message: String
    var actionRequired: String?
    var error: String?
    var manualCommand: String?

    enum CodingKeys: String, CodingKey {
        case status
        case currentVersion = "current_version"
        case previousVersion = "previous_version"
        case newVersion = "new_version"
        case message
        case actionRequired = "action_required"
        case error
        case manualCommand = "manual_command"
    }
}

// MARK: - Update Tool

enum UpdateTool {
    static let name = "update"
    static let description = """
        Check for and install iMessage Max updates.

        This tool checks Homebrew for a newer version and installs it if available.
        After updating, Claude Desktop needs to be restarted to use the new version.
        """

    // MARK: - Tool Registration

    static func register(on server: Server) {
        server.registerTool(
            name: name,
            description: description,
            inputSchema: InputSchema.object(
                properties: [:],
                required: []
            ),
            annotations: .init(
                title: "Update iMessage Max",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: true
            )
        ) { _ in
            try await execute()
        }
    }

    // MARK: - Execution

    private static func execute() async throws -> [Tool.Content] {
        // Check if update is available
        let checkResult = await checkForUpdate()

        switch checkResult {
        case .upToDate:
            let result = UpdateResult(
                status: "up_to_date",
                currentVersion: Version.current,
                message: "You're running the latest version of iMessage Max."
            )
            return [.text(try FormatUtils.encodeJSON(result))]

        case .updateAvailable(let newVersion):
            // Perform the update
            let upgradeResult = await performUpgrade()

            switch upgradeResult {
            case .success:
                let result = UpdateResult(
                    status: "updated",
                    currentVersion: Version.current,
                    previousVersion: Version.current,
                    newVersion: newVersion,
                    message: "Successfully updated from \(Version.current) to \(newVersion). Please restart Claude Desktop (Cmd+Q, then reopen) to use the new version.",
                    actionRequired: "Restart Claude Desktop"
                )
                return [.text(try FormatUtils.encodeJSON(result))]

            case .failure(let error):
                let result = UpdateResult(
                    status: "update_failed",
                    currentVersion: Version.current,
                    message: "Automatic update failed. Please run the manual command in your terminal.",
                    error: error,
                    manualCommand: "brew upgrade imessage-max"
                )
                return [.text(try FormatUtils.encodeJSON(result))]
            }

        case .checkFailed(let error):
            let result = UpdateResult(
                status: "update_failed",
                currentVersion: Version.current,
                message: "Failed to check for updates. Please run the manual command in your terminal.",
                error: error,
                manualCommand: "brew outdated imessage-max"
            )
            return [.text(try FormatUtils.encodeJSON(result))]
        }
    }

    // MARK: - Private Types

    private enum CheckResult {
        case upToDate
        case updateAvailable(String)
        case checkFailed(String)
    }

    private enum UpgradeResult {
        case success
        case failure(String)
    }

    // MARK: - Update Check

    /// Check if an update is available via Homebrew
    private static func checkForUpdate() async -> CheckResult {
        // Try Apple Silicon path first, then Intel
        let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

        for brewPath in brewPaths {
            guard FileManager.default.fileExists(atPath: brewPath) else {
                continue
            }

            do {
                let result = try await runProcess(
                    brewPath,
                    arguments: ["outdated", "imessage-max"],
                    timeout: 30
                )

                // If output is empty, no update available
                let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if output.isEmpty {
                    return .upToDate
                }

                // Parse output to get new version
                if let newVersion = parseOutdatedOutput(output) {
                    return .updateAvailable(newVersion)
                }

                // If we got output but couldn't parse it, still report update available
                return .updateAvailable("newer")

            } catch ProcessError.timeout {
                return .checkFailed("Update check timed out")
            } catch ProcessError.failed(_, let stderr) {
                // brew outdated returns exit code 1 when no formula is found
                // but exit code 0 when formula exists (even if up to date)
                if stderr.contains("No such keg") || stderr.contains("No formula") {
                    continue  // Formula not installed via Homebrew
                }
                return .checkFailed(stderr.isEmpty ? "Unknown error" : stderr)
            } catch {
                return .checkFailed(error.localizedDescription)
            }
        }

        return .checkFailed("Homebrew not found. Install via https://brew.sh")
    }

    /// Parse brew outdated output to extract new version
    private static func parseOutdatedOutput(_ output: String) -> String? {
        // Output format variations:
        // "imessage-max (1.0.0) < 1.1.0"
        // "imessage-max 1.0.0 -> 1.1.0"
        // "imessage-max (1.0.0) != 1.1.0"
        let lines = output.split(separator: "\n")
        for line in lines {
            let lineStr = String(line)
            if lineStr.contains("imessage-max") {
                // Try to extract version after < or -> or !=
                for separator in ["< ", "-> ", "!= "] {
                    if let range = lineStr.range(of: separator) {
                        let version = String(lineStr[range.upperBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .components(separatedBy: " ").first ?? ""
                        if !version.isEmpty {
                            return version
                        }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Upgrade

    /// Perform the upgrade via Homebrew
    private static func performUpgrade() async -> UpgradeResult {
        let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

        for brewPath in brewPaths {
            guard FileManager.default.fileExists(atPath: brewPath) else {
                continue
            }

            do {
                _ = try await runProcess(
                    brewPath,
                    arguments: ["upgrade", "imessage-max"],
                    timeout: 120
                )
                return .success
            } catch ProcessError.timeout {
                return .failure("Upgrade timed out")
            } catch ProcessError.failed(_, let stderr) {
                return .failure(stderr.isEmpty ? "Unknown error" : stderr)
            } catch {
                return .failure(error.localizedDescription)
            }
        }

        return .failure("Homebrew not found")
    }

    // MARK: - Process Execution

    private enum ProcessError: Error {
        case notFound
        case timeout
        case failed(Int32, String)
    }

    private struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Run a process with timeout
    private static func runProcess(
        _ path: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask {
                try process.run()
                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if process.terminationStatus != 0 {
                    throw ProcessError.failed(process.terminationStatus, stderr)
                }

                return ProcessResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProcessError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

}
