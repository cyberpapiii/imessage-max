// Sources/iMessageMax/Utilities/AppleScript.swift
import Foundation

enum SendError: LocalizedError {
    case automationPermissionRequired
    case messagesAppUnavailable
    case recipientNotFound(String)
    case timeout
    case failed(String)
    case invalidParams(String)

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
        case .invalidParams(let message):
            return message
        }
    }
}

enum AppleScriptRunner {
    /// Send a message to a recipient via AppleScript and Messages.app
    /// - Parameters:
    ///   - recipient: Phone number, email, or chat GUID
    ///   - message: Message text to send
    /// - Returns: Result indicating success or specific error
    static func send(to recipient: String, message: String) -> Result<Void, SendError> {
        // Input length validation
        guard recipient.count <= 100 else {
            return .failure(.invalidParams("Recipient too long"))
        }
        guard message.count <= 20_000 else {
            return .failure(.invalidParams("Message too long (max 20,000 chars)"))
        }

        // Static AppleScript template — no string interpolation.
        // Values are passed via environment variables to prevent injection.
        let script = """
            set recipientId to system attribute "IMSG_RECIPIENT"
            set messageText to system attribute "IMSG_MESSAGE"
            tell application "Messages"
                set targetService to 1st account whose service type = iMessage
                set targetBuddy to participant recipientId of targetService
                send messageText to targetBuddy
            end tell
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        // Clean environment: only the two variables the script needs.
        // Do NOT inherit the parent process environment.
        process.environment = [
            "IMSG_RECIPIENT": recipient,
            "IMSG_MESSAGE": message
        ]

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
