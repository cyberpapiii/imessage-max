// Sources/iMessageMax/Tools/Diagnose.swift
import Foundation
import MCP

/// Result type for diagnose tool
struct DiagnoseResult: Codable {
    struct DatabaseStatus: Codable {
        let accessible: Bool
        let status: String
        let path: String
        let fix: String?
    }

    struct ContactsStatus: Codable {
        let authorized: Bool
        let status: String
        let loaded: Int?
        let fix: String?
    }

    struct Capabilities: Codable {
        let sendTextToParticipant: Bool
        let sendTextToChat: Bool
        let sendFileToParticipant: Bool
        let sendFileToChat: Bool
        let replyToSupported: Bool
        let tapbackSupported: Bool
        let editUnsendSupported: Bool

        enum CodingKeys: String, CodingKey {
            case sendTextToParticipant = "send_text_to_participant"
            case sendTextToChat = "send_text_to_chat"
            case sendFileToParticipant = "send_file_to_participant"
            case sendFileToChat = "send_file_to_chat"
            case replyToSupported = "reply_to_supported"
            case tapbackSupported = "tapback_supported"
            case editUnsendSupported = "edit_unsend_supported"
        }
    }

    let version: String
    let processId: Int32
    let status: String
    let database: DatabaseStatus
    let contacts: ContactsStatus
    let capabilities: Capabilities

    enum CodingKeys: String, CodingKey {
        case version
        case processId = "process_id"
        case status
        case database
        case contacts
        case capabilities
    }
}

enum DiagnoseTool {
    // MARK: - Tool Registration

    static func register(on server: Server, resolver: ContactResolver) {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([:]),
            "additionalProperties": false,
        ])

        server.registerTool(
            name: "diagnose",
            description: "Diagnose iMessage MCP configuration and permissions. Use this to troubleshoot database access, contacts, or permission issues.",
            inputSchema: inputSchema,
            outputSchema: OutputSchema.object,
            annotations: Tool.Annotations(
                title: "Diagnose",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { _ in
            let result = try await execute(resolver: resolver)
            return [.plainText(try FormatUtils.encodeJSON(result))]
        }
    }

    /// Diagnose iMessage MCP configuration and permissions.
    ///
    /// Use this tool to troubleshoot issues with contact resolution,
    /// database access, or permission problems.
    ///
    /// - Parameter resolver: ContactResolver for checking contacts status
    /// - Returns: DiagnoseResult with database access status, contacts status, version info, and system info
    static func execute(resolver: ContactResolver) async throws -> DiagnoseResult {
        let processId = ProcessInfo.processInfo.processIdentifier

        // Check database access (Full Disk Access)
        let (dbAccessible, dbStatus) = Database.checkAccess()
        let databasePath = Database.defaultPath

        var databaseFix: String? = nil
        if !dbAccessible {
            if dbStatus == "permission_denied" {
                databaseFix = "Grant Full Disk Access: System Settings -> Privacy & Security -> " +
                    "Full Disk Access -> Add your terminal app or the imessage-max executable"
            } else if dbStatus == "database_not_found" {
                databaseFix = "iMessage database not found. Ensure iMessage is set up and " +
                    "has sent/received at least one message."
            }
        }

        // Check Contacts access
        let (contactsAuthorized, authorizationStatus) = ContactResolver.authorizationStatus()

        var contactsStatus = authorizationStatus
        var contactsLoaded: Int? = nil
        var contactsFix: String? = nil

        if contactsAuthorized {
            do {
                try await resolver.initialize()
                let stats = await resolver.getStats()
                contactsLoaded = stats.handleCount
            } catch {
                contactsStatus = "\(authorizationStatus)_load_failed"
                contactsFix = "Contacts permission is granted, but contacts could not be loaded: \(error.localizedDescription)"
            }
        } else {
            contactsFix = "Grant Contacts access: System Settings -> Privacy & Security -> " +
                "Contacts -> Add your terminal app or the imessage-max executable"
        }

        // Overall status
        let allGood = dbAccessible && contactsAuthorized
        let overallStatus = allGood ? "ready" : "needs_setup"

        return DiagnoseResult(
            version: Version.current,
            processId: processId,
            status: overallStatus,
            database: .init(
                accessible: dbAccessible,
                status: dbStatus,
                path: databasePath,
                fix: databaseFix
            ),
            contacts: .init(
                authorized: contactsAuthorized,
                status: contactsStatus,
                loaded: contactsLoaded,
                fix: contactsFix
            ),
            capabilities: .init(
                sendTextToParticipant: true,
                sendTextToChat: true,
                sendFileToParticipant: true,
                sendFileToChat: true,
                replyToSupported: false,
                tapbackSupported: false,
                editUnsendSupported: false
            )
        )
    }
}
