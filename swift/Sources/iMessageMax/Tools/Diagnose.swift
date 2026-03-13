// Sources/iMessageMax/Tools/Diagnose.swift
import Foundation
import MCP

/// Result type for diagnose tool
struct DiagnoseResult: Codable {
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
    let databaseAccessible: Bool
    let databaseStatus: String
    let databasePath: String
    let databaseFix: String?
    let contactsAuthorized: Bool
    let contactsStatus: String
    let contactsLoaded: Int?
    let contactsFix: String?
    let status: String
    let capabilities: Capabilities

    enum CodingKeys: String, CodingKey {
        case version
        case processId = "process_id"
        case databaseAccessible = "database_accessible"
        case databaseStatus = "database_status"
        case databasePath = "database_path"
        case databaseFix = "database_fix"
        case contactsAuthorized = "contacts_authorized"
        case contactsStatus = "contacts_status"
        case contactsLoaded = "contacts_loaded"
        case contactsFix = "contacts_fix"
        case status
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
            annotations: Tool.Annotations(
                title: "Diagnose",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { _ in
            let result = try await execute(resolver: resolver)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let json = try encoder.encode(result)
            return [.text(String(data: json, encoding: .utf8) ?? "{}")]
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
        let (contactsAuthorized, contactsStatus) = ContactResolver.authorizationStatus()

        var contactsLoaded: Int? = nil
        var contactsFix: String? = nil

        if contactsAuthorized {
            try await resolver.initialize()
            let stats = await resolver.getStats()
            contactsLoaded = stats.handleCount
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
            databaseAccessible: dbAccessible,
            databaseStatus: dbStatus,
            databasePath: databasePath,
            databaseFix: databaseFix,
            contactsAuthorized: contactsAuthorized,
            contactsStatus: contactsStatus,
            contactsLoaded: contactsLoaded,
            contactsFix: contactsFix,
            status: overallStatus,
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
