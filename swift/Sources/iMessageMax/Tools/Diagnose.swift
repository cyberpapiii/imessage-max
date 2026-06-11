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

/// Result type for the diagnose tool.
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
                "unsupported" means the feature does not exist — do not attempt it or expose \
                it to the user as an option. "permission-gated" means a macOS permission must \
                be granted before the feature can work; surface the fix field to the user. \
                "risky-private" means the feature requires explicit confirmation (pass confirm: true). \
                "unverified" means the capability state cannot be determined at diagnose time; \
                treat it as potentially available but proceed cautiously. "unavailable" means no \
                implementation exists in the current backend — do not attempt and do not mention \
                to the user as a near-term option. The database.accessible field governs whether \
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

    /// Diagnose iMessage MCP configuration, permissions, and runtime capabilities.
    ///
    /// All three probes are injectable for testability. CI runners return
    /// "not_determined" for automation and may lack Full Disk Access, so tests
    /// MUST inject rather than call the real probes.
    ///
    /// - Parameters:
    ///   - resolver: ContactResolver for loading the contacts count when authorized.
    ///   - dbProbe: Probe for database/Full Disk Access; defaults to `Database.checkAccess()`.
    ///   - contactsProbe: Probe for contacts authorization; defaults to `ContactResolver.authorizationStatus()`.
    ///   - automationProbe: Probe for Automation permission; defaults to the real TCC check.
    /// - Returns: DiagnoseResult with health fields and the full 15-key capability contract.
    static func execute(
        resolver: ContactResolver,
        dbProbe: DatabaseProbe = { Database.checkAccess() },
        contactsProbe: ContactsProbe = { ContactResolver.authorizationStatus() },
        automationProbe: AutomationProbe = { AutomationPermission.checkAutomationPermission() }
    ) async throws -> DiagnoseResult {
        let processId = ProcessInfo.processInfo.processIdentifier
        let databasePath = Database.defaultPath

        // Probe 1: Full Disk Access
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

        // Probe 2: Contacts authorization
        let (contactsAuthorized, authorizationStatus) = contactsProbe()

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

        // Probe 3: Automation permission
        let (automationOk, automationStatus) = automationProbe()

        // Overall health status
        let allGood = dbOk && contactsAuthorized
        let overallStatus = allGood ? "ready" : "needs_setup"

        // MARK: - Capability derivation (design §2.4)

        let automationFix = "Grant Automation access: System Settings -> Privacy & Security -> " +
            "Automation -> Enable Messages for your terminal app or the imessage-max executable"

        // Send modes: driven solely by automation probe
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

        // send_file_group: risky-private when automation ok; otherwise same as other send modes
        let sendFileGroupState: String
        let sendFileGroupNote: String?
        let sendFileGroupFix: String?
        switch (automationOk, automationStatus) {
        case (true, _):
            sendFileGroupState = "risky-private"
            sendFileGroupNote = "Group file sends require confirm:true; routing cannot be verified before send"
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

        // attachments_read: db-gated
        let attachmentsReadState = dbOk ? "supported" : "permission-gated"
        let attachmentsReadFix = dbOk ? nil : "Grant Full Disk Access to read attachment content"

        // attachments_offloaded: supported with note when DB accessible; permission-gated otherwise
        let attachmentsOffloadedState = dbOk ? "supported" : "permission-gated"
        let attachmentsOffloadedNote: String? = dbOk
            ? "Offloaded files trigger iCloud download; retry get_attachment after a few seconds"
            : nil

        // perm_full_disk
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

        // perm_contacts
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

        // perm_automation
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
                path: databasePath,
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
