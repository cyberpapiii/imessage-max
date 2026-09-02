// Sources/iMessageMax/Tools/Diagnose.swift
import Foundation
import MCP

/// A single capability entry in the capability contract.
/// `state` uses the vocabulary from design §2.1.
/// `note` / `fix` / `detail` are omitted when nil for token efficiency.
struct Capability: Codable, Equatable {
    let state: String
    let note: String?
    let fix: String?
    let detail: String?

    init(state: String, note: String? = nil, fix: String? = nil, detail: String? = nil) {
        self.state = state
        self.note = note
        self.fix = fix
        self.detail = detail
    }
}

/// Probe type for database accessibility checks. Injectable so tests stay hermetic.
typealias DatabaseProbe = @Sendable () -> (ok: Bool, status: String)

/// Probe type for contacts authorization checks. Injectable so tests stay hermetic.
typealias ContactsProbe = @Sendable () -> (authorized: Bool, status: String)

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

    let version: String
    let processId: Int32
    let status: String
    let database: DatabaseStatus
    let contacts: ContactsStatus
    /// Capability contract: 15 keys per design §2.2.
    let capabilities: [String: Capability]

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
            description: """
                Use diagnose before attempting any send, attachment, or live-inbox operation. \
                Check capabilities.<key>.state for each feature you plan to use. \
                "supported" means the feature is available and probed on this install. \
                "unsupported" means the feature does not exist. Do not attempt it or offer \
                it to the user. "permission-gated" means a macOS permission must \
                be granted before the feature can work; show the fix field to the user. \
                "unverified" means diagnose could not determine the state. The feature may \
                work; try it, but do not promise the user it will. "unavailable" means the \
                current backend has no implementation. Do not attempt it and do not tell the \
                user it is coming. The database.accessible field governs whether \
                all read tools (get_messages, list_chats, search, etc.) will work. A "needs_setup" \
                top-level status means at least one required permission is missing; resolve it \
                before proceeding. Use chat.name in user-facing summaries and chat ids only in \
                follow-up tool calls. Refer to chats by name when talking to users.
                """,
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

    /// All three probes are injectable for testability. CI runners return
    /// "not_determined" for automation and may lack Full Disk Access, so tests
    /// MUST inject rather than call the real probes.
    static func execute(
        resolver: ContactResolver,
        dbProbe: DatabaseProbe = { Database.checkAccess() },
        contactsProbe: ContactsProbe = { ContactResolver.authorizationStatus() },
        automationProbe: AutomationProbe = { AutomationPermission.checkAutomationPermission() }
    ) async throws -> DiagnoseResult {
        let processId = ProcessInfo.processInfo.processIdentifier
        let databasePath = Database.defaultPath

        let (dbOk, dbStatus) = dbProbe()

        var databaseFix: String? = nil
        if !dbOk {
            if dbStatus == "permission_denied" {
                databaseFix = "Grant Full Disk Access: System Settings -> Privacy & Security -> " +
                    "Full Disk Access -> Add your terminal app or the imessage-max executable"
            } else if dbStatus == "database_not_found" {
                databaseFix = "iMessage database not found. Ensure iMessage is set up and " +
                    "has sent/received at least one message."
            }
        }

        let (contactsAuthorized, authorizationStatus) = contactsProbe()

        var contactsStatus = authorizationStatus
        var contactsLoaded: Int? = nil
        var contactsFix: String? = nil

        if contactsAuthorized {
            do {
                try await resolver.initialize()
                let stats = await resolver.getStats()
                contactsLoaded = stats.handleCount
                if stats.skippedForCI {
                    contactsStatus = "skipped_ci"
                    contactsFix = "CI=true is set in this process's environment, so contact "
                        + "loading was skipped and no names will resolve. Unset CI to load contacts."
                }
            } catch {
                contactsStatus = "\(authorizationStatus)_load_failed"
                // CNContactStore errors routinely embed local paths and the
                // username; the detail goes to stderr, the client gets a
                // fixed string.
                contactsFix = "Contacts permission is granted, but "
                    + ClientErrorMessages.internalDetail(error, context: "loading contacts")
            }
        } else {
            contactsFix = "Grant Contacts access: System Settings -> Privacy & Security -> " +
                "Contacts -> Add your terminal app or the imessage-max executable"
        }

        let (automationOk, automationStatus) = automationProbe()

        let allGood = dbOk && contactsAuthorized && contactsStatus != "skipped_ci"
        let overallStatus = allGood ? "ready" : "needs_setup"

        // MARK: - Capability derivation (design §2.4)

        let automationFix = "Grant Automation access: System Settings -> Privacy & Security -> " +
            "Automation -> Enable Messages for your terminal app or the imessage-max executable"

        let sendState: String
        let sendFix: String?
        switch (automationOk, automationStatus) {
        case (true, _):
            sendState = "supported"
            sendFix = nil
        case (false, "denied"):
            sendState = "permission-gated"
            sendFix = automationFix
        default:
            sendState = "unverified"
            sendFix = nil
        }

        // send_file_group: supported with a routing caveat when automation ok;
        // otherwise same as other send modes
        let sendFileGroupState: String
        let sendFileGroupNote: String?
        let sendFileGroupFix: String?
        switch (automationOk, automationStatus) {
        case (true, _):
            sendFileGroupState = "supported"
            sendFileGroupNote = "Group file routing cannot be verified before send; check the delivered_to and chat fields in the response"
            sendFileGroupFix = nil
        case (false, "denied"):
            sendFileGroupState = "permission-gated"
            sendFileGroupNote = nil
            sendFileGroupFix = automationFix
        default:
            sendFileGroupState = "unverified"
            sendFileGroupNote = nil
            sendFileGroupFix = nil
        }

        // verified_send: db.ok && automation.ok → supported; db.ok && !automation.ok → degraded;
        //                !db.ok → permission-gated
        let verifiedSendState: String
        let verifiedSendFix: String?
        let verifiedSendDetail: String?
        if !dbOk {
            verifiedSendState = "permission-gated"
            verifiedSendFix = "Grant Full Disk Access to enable DB re-read verification after sends"
            verifiedSendDetail = nil
        } else if automationOk {
            verifiedSendState = "supported"
            verifiedSendFix = nil
            verifiedSendDetail = "db_reread"
        } else {
            verifiedSendState = "degraded"
            verifiedSendFix = nil
            verifiedSendDetail = nil
        }

        let attachmentsReadState = dbOk ? "supported" : "permission-gated"
        let attachmentsReadFix = dbOk ? nil : "Grant Full Disk Access to read attachment content"

        let attachmentsOffloadedState = dbOk ? "supported" : "permission-gated"
        let attachmentsOffloadedNote: String? = dbOk
            ? "Offloaded files trigger iCloud download; retry get_attachment after a few seconds"
            : nil

        let permFullDiskState: String
        let permFullDiskFix: String?
        switch dbStatus {
        case "accessible":
            permFullDiskState = "supported"
            permFullDiskFix = nil
        case "permission_denied":
            permFullDiskState = "permission-gated"
            permFullDiskFix = databaseFix
        default:
            permFullDiskState = "degraded"
            permFullDiskFix = databaseFix
        }

        let permContactsState: String
        let permContactsFix: String?
        switch authorizationStatus {
        case "authorized", "limited":
            permContactsState = "supported"
            permContactsFix = nil
        case "denied", "restricted":
            permContactsState = "permission-gated"
            permContactsFix = contactsFix
        default:
            permContactsState = "unverified"
            permContactsFix = nil
        }

        let permAutomationState: String
        let permAutomationFix: String?
        switch (automationOk, automationStatus) {
        case (true, _):
            permAutomationState = "supported"
            permAutomationFix = nil
        case (false, "denied"):
            permAutomationState = "permission-gated"
            permAutomationFix = automationFix
        default:
            permAutomationState = "unverified"
            permAutomationFix = nil
        }

        let capabilities: [String: Capability] = [
            "send_text_dm":          Capability(state: sendState, fix: sendFix),
            "send_text_group":       Capability(state: sendState, fix: sendFix),
            "send_file_dm":          Capability(state: sendState, fix: sendFix),
            "send_file_group":       Capability(
                state: sendFileGroupState,
                note: sendFileGroupNote,
                fix: sendFileGroupFix
            ),
            "verified_send":         Capability(
                state: verifiedSendState,
                fix: verifiedSendFix,
                detail: verifiedSendDetail
            ),
            "attachments_read":      Capability(state: attachmentsReadState, fix: attachmentsReadFix),
            "attachments_offloaded": Capability(state: attachmentsOffloadedState, note: attachmentsOffloadedNote),
            "reply_threading":       Capability(state: "unsupported"),
            "tapbacks":              Capability(state: "unsupported"),
            "edit_unsend":           Capability(state: "unsupported"),
            "live_inbox":            Capability(state: "unavailable"),
            "perm_full_disk":        Capability(state: permFullDiskState, fix: permFullDiskFix),
            "perm_contacts":         Capability(state: permContactsState, fix: permContactsFix),
            "perm_automation":       Capability(state: permAutomationState, fix: permAutomationFix),
            "rich_backend":          Capability(state: "unavailable"),
        ]

        return DiagnoseResult(
            version: Version.current,
            processId: processId,
            status: overallStatus,
            database: .init(
                accessible: dbOk,
                status: dbStatus,
                // Keep the path actionable for the operator without echoing
                // their username to the client.
                path: (databasePath as NSString).abbreviatingWithTildeInPath,
                fix: databaseFix
            ),
            contacts: .init(
                authorized: contactsAuthorized,
                status: contactsStatus,
                loaded: contactsLoaded,
                fix: contactsFix
            ),
            capabilities: capabilities
        )
    }
}
