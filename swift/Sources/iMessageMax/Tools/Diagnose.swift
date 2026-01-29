// Sources/iMessageMax/Tools/Diagnose.swift
import Foundation

/// Result type for diagnose tool
struct DiagnoseResult: Codable {
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
    }
}

enum DiagnoseTool {
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
            status: overallStatus
        )
    }
}
