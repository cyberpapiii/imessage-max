// Sources/iMessageMax/Utilities/AppleScript.swift
import Foundation

enum SendError: LocalizedError {
    case automationPermissionRequired
    case messagesAppUnavailable
    case recipientNotFound(String)
    case timeout
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .automationPermissionRequired:
            return """
                Messages.app Automation permission required. \
                When prompted, click 'OK' to allow iMessage Max to send messages. \
                If you missed the prompt: System Settings → Privacy & Security → \
                Automation → Enable Messages.app for your terminal/application.
                """
        case .messagesAppUnavailable:
            return "Messages.app is not responding. Please open Messages.app and try again."
        case .recipientNotFound(let recipient):
            return "Could not find recipient '\(recipient)' in Messages.app."
        case .timeout:
            return "Send operation timed out. Messages.app may be unresponsive."
        case .failed(let message):
            return "Send failed: \(message)"
        }
    }
}

enum AppleScriptRunner {
    /// Escape a string for safe use in AppleScript.
    /// Handles backslashes, double quotes, and newlines.
    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// Send a message to a recipient via AppleScript and Messages.app
    /// - Parameters:
    ///   - recipient: Phone number, email, or chat GUID
    ///   - message: Message text to send
    /// - Returns: Result indicating success or specific error
    static func send(to recipient: String, message: String) -> Result<Void, SendError> {
        let escapedRecipient = escape(recipient)
        let escapedMessage = escape(message)

        let script = """
            tell application "Messages"
                set targetService to 1st account whose service type = iMessage
                set targetBuddy to participant "\(escapedRecipient)" of targetService
                send "\(escapedMessage)" to targetBuddy
            end tell
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()

            // Wait with timeout using semaphore
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                process.waitUntilExit()
                semaphore.signal()
            }

            let result = semaphore.wait(timeout: .now() + .seconds(30))
            if result == .timedOut {
                process.terminate()
                return .failure(.timeout)
            }

            if process.terminationStatus != 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: data, encoding: .utf8)?.lowercased() ?? ""

                // Detect Automation permission errors
                if stderr.contains("not allowed") ||
                    stderr.contains("not permitted") ||
                    stderr.contains("assistive access")
                {
                    return .failure(.automationPermissionRequired)
                }

                // Detect if Messages app isn't running/responding
                if stderr.contains("connection is invalid") ||
                    stderr.contains("application isn't running")
                {
                    return .failure(.messagesAppUnavailable)
                }

                // Detect if recipient doesn't exist
                if stderr.contains("can't get participant") ||
                    stderr.contains("doesn't understand")
                {
                    return .failure(.recipientNotFound(recipient))
                }

                return .failure(.failed(stderr))
            }

            return .success(())
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}
