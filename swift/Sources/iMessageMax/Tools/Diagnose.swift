import Foundation
import IMessageMaxContract
import MCP

/// Probe type for database accessibility checks. Injectable so tests stay hermetic.
typealias DatabaseProbe = @Sendable () -> (ok: Bool, status: String)

/// Whether this executable carries NSContactsUsageDescription in an embedded Info.plist.
typealias UsageDescriptionProbe = @Sendable () -> Bool

/// Probe type for optional chat.db column flags. Injectable so tests stay hermetic.
typealias SchemaProbe = @Sendable () -> SchemaCapabilities?

/// Probe type for the live-inbox watcher. Injectable so tests stay hermetic.
typealias LiveInboxProbe = @Sendable () -> Bool

enum DiagnoseTool {
    // MARK: - Tool Registration

    static func definition(db: Database, resolver: ContactResolver, liveInbox: @escaping LiveInboxProbe) -> ToolDefinition {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([:]),
            "additionalProperties": false,
        ])

        return ToolDefinition(
            name: DiagnoseResult.toolName,
            description: """
                Use diagnose before attempting any send, attachment, or live inbox \
                (push notifications when new messages land; `supported` only in \
                HTTP mode while the watcher runs) operation. \
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
            let result = try await execute(
                resolver: resolver,
                schemaProbe: { try? db.schema() },
                liveInboxProbe: liveInbox
            )
            return [.plainText(try FormatUtils.encodeJSON(result))]
        }
    }

    /// The process that opens chat.db is the one that needs the grant. For
    /// the launchd service that is the release binary; for stdio it is the
    /// binary the MCP client spawned. Tilde-abbreviated: diagnose must not
    /// echo the username (DiagnoseToolTests.testResponseDoesNotContainHomeDirectory).
    static var executableForGrant: String {
        let raw = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ServiceDefaults.executableName
        return (raw as NSString).abbreviatingWithTildeInPath
    }

    static func fullDiskAccessFix(executable: String = executableForGrant) -> String {
        "Full Disk Access is missing for the process reading chat.db (\(executable)). "
            + "1) System Settings -> Privacy & Security -> Full Disk Access -> add that executable "
            + "(or the app that launches it, such as Terminal). "
            + "2) If it is already listed, toggle it off and on: a grant bound to an older "
            + "code signature looks present but does not work. "
            + "3) The grant applies only to newly launched processes; relaunch this server: "
            + "`make restart` in swift/ (launchctl bootout, then bootstrap, of ~/\(ServiceDefaults.launchAgentPath)), "
            + "or reconnect the MCP client for stdio. "
            + "4) To bisect, run sqlite3 -readonly ~/Library/Messages/chat.db 'pragma quick_check;' "
            + "from a terminal: 'ok' means the terminal has access and this process does not; "
            + "'unable to open database file' means the user lacks it everywhere."
    }

    /// CI runners report "not_determined" for automation and may lack Full
    /// Disk Access, so tests inject these probes instead of the real ones.
    static func execute(
        resolver: ContactResolver,
        dbProbe: DatabaseProbe = { Database.checkAccess() },
        automationProbe: AutomationProbe = { AutomationPermission.checkAutomationPermission() },
        schemaProbe: SchemaProbe = { nil },
        liveInboxProbe: LiveInboxProbe = { false },
        usageDescriptionProbe: UsageDescriptionProbe = { ContactResolver.usageDescriptionEmbedded }
    ) async throws -> DiagnoseResult {
        let (dbOk, rawDBStatus) = dbProbe()
        let dbStatus = DatabaseStatus(rawValue: rawDBStatus)
        let features = dbOk ? schemaProbe()?.features : nil

        var databaseFix: String? = nil
        if !dbOk {
            if dbStatus == .permissionDenied {
                databaseFix = fullDiskAccessFix()
            } else if dbStatus == .databaseNotFound {
                databaseFix = "iMessage database not found. Ensure iMessage is set up and " +
                    "has sent/received at least one message."
            }
        }

        let contacts = await resolver.status()
        let contactsAuthorized = contacts.authorized
        let authorizationStatus = PermissionStatus(rawValue: contacts.authorization)

        var contactsStatus = authorizationStatus
        var contactsLoaded: Int? = nil
        var contactsFix: String? = nil

        if contactsAuthorized {
            if contacts.loadFailed {
                contactsStatus = .loadFailed(authorizationStatus)
                // CNContactStore errors routinely embed local paths and the
                // username; the resolver logged the detail.
                contactsFix = "Contacts permission is granted, but loading contacts failed. Check the server log for details."
            } else {
                contactsLoaded = contacts.handleCount
            }
        } else {
            if authorizationStatus == .notDetermined, !usageDescriptionProbe() {
                contactsStatus = .missingUsageDescription
                contactsFix = "This executable was built without its embedded Info.plist, so macOS "
                    + "cannot prompt for or record a Contacts grant for it. Rebuild with `make build` "
                    + "(or `make sign`), not a bare `swift build`, then run "
                    + "`imessage-max --request-contacts-access` once."
            } else if authorizationStatus == .notDetermined, contacts.accessRequestSkippedHeadless {
                contactsStatus = .notRequestedHeadless
                contactsFix = "This process has no terminal, so it did not ask for Contacts access. "
                    + "Run `imessage-max --request-contacts-access` once (from a terminal or any "
                    + "shell) and approve the \"iMessage Max\" prompt; the grant is recorded for this "
                    + "executable, not for the terminal. Then restart the MCP client or service. "
                    + "A Contacts switch for Terminal or Claude does not apply to this process."
            } else {
                contactsFix = "Grant Contacts access: System Settings -> Privacy & Security -> " +
                    "Contacts -> Add your terminal app or the imessage-max executable"
            }
        }

        let (automationOk, automationStatus) = automationProbe()

        let overallStatus: DiagnoseStatus = dbOk && contactsAuthorized ? .ready : .needsSetup

        // MARK: - Capability derivation (design §2.4)

        let automationFix = "Grant Automation access: System Settings -> Privacy & Security -> " +
            "Automation -> Enable Messages for your terminal app or the imessage-max executable"

        // Only an explicit TCC denial is permission-gated. Messages not
        // running, or no decision yet, leaves sending unverified.
        let automation: Capability
        if automationOk {
            automation = Capability(state: .supported)
        } else if automationStatus == .denied {
            automation = Capability(state: .permissionGated, fix: automationFix)
        } else {
            automation = Capability(state: .unverified)
        }
        let sendFileGroup = automationOk
            ? Capability(
                state: .supported,
                note: "Group file routing cannot be verified before send; check the delivered_to and chat fields in the response")
            : automation

        let verifiedSend: Capability
        if !dbOk {
            verifiedSend = Capability(
                state: .permissionGated,
                fix: "Grant Full Disk Access to enable DB re-read verification after sends")
        } else if automationOk {
            verifiedSend = Capability(state: .supported, detail: "db_reread")
        } else {
            verifiedSend = Capability(state: .degraded)
        }

        let attachmentsRead = dbOk
            ? Capability(state: .supported)
            : Capability(state: .permissionGated, fix: "Grant Full Disk Access to read attachment content")
        let attachmentsOffloaded = dbOk
            ? Capability(
                state: .supported,
                note: "Offloaded files trigger iCloud download; retry get_attachment after a few seconds")
            : Capability(state: .permissionGated)

        let permFullDisk: Capability
        switch dbStatus {
        case .accessible: permFullDisk = Capability(state: .supported)
        case .permissionDenied: permFullDisk = Capability(state: .permissionGated, fix: databaseFix)
        default: permFullDisk = Capability(state: .degraded, fix: databaseFix)
        }

        let permContacts: Capability
        if PermissionStatus.namesAvailable.contains(contactsStatus) {
            permContacts = Capability(state: .supported)
        } else if [.denied, .restricted, .notRequestedHeadless, .missingUsageDescription].contains(contactsStatus) {
            permContacts = Capability(state: .permissionGated, fix: contactsFix)
        } else {
            permContacts = Capability(state: .unverified)
        }

        let capabilities: [CapabilityKey: Capability] = [
            .sendTextDM: automation,
            .sendTextGroup: automation,
            .sendFileDM: automation,
            .sendFileGroup: sendFileGroup,
            .verifiedSend: verifiedSend,
            .attachmentsRead: attachmentsRead,
            .attachmentsOffloaded: attachmentsOffloaded,
            .replyThreading: Capability(state: .unsupported),
            .tapbacks: Capability(state: .unsupported),
            .editUnsend: Capability(state: .unsupported),
            .liveInbox: Capability(
                state: liveInboxProbe() ? .supported : .unavailable,
                detail: "\(NewMessagesNotification.name) over the legacy session SSE stream; stateless clients poll get_messages_since"
            ),
            .permFullDisk: permFullDisk,
            .permContacts: permContacts,
            .permAutomation: Capability(
                state: automation.state, fix: automation.fix, detail: automationStatus.rawValue),
            .richBackend: Capability(state: .unavailable),
        ]

        return DiagnoseResult(
            version: Version.current,
            processID: ProcessInfo.processInfo.processIdentifier,
            status: overallStatus,
            database: .init(
                accessible: dbOk,
                status: dbStatus,
                // Keep the path actionable for the operator without echoing
                // their username to the client.
                path: (Database.defaultPath as NSString).abbreviatingWithTildeInPath,
                fix: databaseFix,
                features: features
            ),
            contacts: .init(
                authorized: contactsAuthorized,
                status: contactsStatus,
                loaded: contactsLoaded,
                fix: contactsFix
            ),
            capabilities: Dictionary(uniqueKeysWithValues: capabilities.map { ($0.key.rawValue, $0.value) })
        )
    }
}
