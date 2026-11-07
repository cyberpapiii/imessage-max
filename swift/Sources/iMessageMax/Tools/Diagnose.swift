import Foundation
import IMessageMaxContract
import MCP

typealias DatabaseProbe = @Sendable () -> (ok: Bool, status: DatabaseStatus)

typealias UsageDescriptionProbe = @Sendable () -> Bool

typealias SchemaProbe = @Sendable () -> SchemaCapabilities?

typealias LiveInboxProbe = @Sendable () -> Bool

enum DiagnoseTool {
    static func definition(db: Database, resolver: ContactResolver, liveInbox: @escaping LiveInboxProbe) -> ToolDefinition {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([:]),
            "additionalProperties": false,
        ])

        return ToolDefinition(
            name: DiagnoseResult.toolName,
            description: """
                Call diagnose before you attempt any send, attachment, or live inbox operation. \
                Live inbox means push notifications when new messages arrive. It is `supported` \
                only in HTTP mode while the watcher runs. \
                Check capabilities.<key>.state for each feature you plan to use. \
                "supported" means the feature is available and probed on this install. \
                "unsupported" means the feature does not exist. Do not attempt it or offer \
                it to the user. "permission-gated" means the user must grant a macOS permission \
                before the feature can work. Show the fix field to the user. \
                "unverified" means diagnose could not determine the state. The feature may \
                work, so try it, but do not promise the user it will. "unavailable" means the \
                current backend has no implementation. Do not attempt it and do not tell the \
                user it is coming. "degraded" means the feature works only in part. Show the \
                fix field to the user when it has one. The database.accessible field tells you whether \
                all read tools (get_messages, list_chats, search, and the rest) will work. \
                A top-level status of "needs_setup" means at least one required permission \
                is missing. Resolve it before you continue. Use chat.name in user-facing \
                summaries and use chat ids only in follow-up tool calls. Refer to chats by \
                name when talking to users.
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

    static var executableForGrant: String {
        grantTarget(executable: Bundle.main.executablePath ?? CommandLine.arguments.first ?? ServiceDefaults.executableName)
    }

    /// The app that holds the grant when this helper runs inside one, since
    /// macOS charges an in-bundle helper's privacy access to its app.
    static func grantTarget(executable: String) -> String {
        let suffix = "/" + ServiceDefaults.helperBundlePath
        let app = executable.dropLast(suffix.count)
        let target = executable.hasSuffix(suffix) && app.hasSuffix(".app") ? String(app) : executable
        return (target as NSString).abbreviatingWithTildeInPath
    }

    static func fullDiskAccessFix(executable: String = executableForGrant) -> String {
        "Full Disk Access is missing for the process reading chat.db (\(executable)). "
            + "1) System Settings -> Privacy & Security -> Full Disk Access -> add that app or executable "
            + "(or the app that launches it, such as Terminal). "
            + "2) If it is already listed, toggle it off and on: a grant bound to an older "
            + "code signature looks present but does not work. "
            + "3) The grant applies only to newly launched processes; relaunch this server: "
            + "Restart iMessage Max from its menu bar app, or run `make restart` in swift/ "
            + "(launchctl kickstart -k gui/<uid>/\(ServiceDefaults.launchdLabel)), "
            + "or reconnect the MCP client for stdio. "
            + "4) To bisect, run sqlite3 -readonly ~/Library/Messages/chat.db 'pragma quick_check;' "
            + "from a terminal: 'ok' means the terminal has access and this process does not; "
            + "'unable to open database file' means the user lacks it everywhere."
    }

    static func execute(
        resolver: ContactResolver,
        dbProbe: DatabaseProbe = { Database.checkAccess() },
        automationProbe: AutomationProbe = { AutomationPermission.checkAutomationPermission() },
        schemaProbe: SchemaProbe = { nil },
        liveInboxProbe: LiveInboxProbe = { false },
        usageDescriptionProbe: UsageDescriptionProbe = { ContactResolver.usageDescriptionEmbedded }
    ) async throws -> DiagnoseResult {
        let (dbOk, dbStatus) = dbProbe()
        let features = dbOk ? schemaProbe()?.features : nil

        var databaseFix: String? = nil
        if !dbOk {
            if dbStatus == .permissionDenied {
                databaseFix = fullDiskAccessFix()
            } else if dbStatus == .databaseNotFound {
                databaseFix = "iMessage database not found. Set up iMessage and make sure it " +
                    "has sent or received at least one message."
            }
        }

        let contacts = await resolver.status()
        let contactsAuthorized = contacts.authorized
        let authorizationStatus = contacts.authorization

        var contactsStatus = authorizationStatus
        var contactsLoaded: Int? = nil
        var contactsFix: String? = nil

        if contactsAuthorized {
            if contacts.loadFailed {
                contactsStatus = .loadFailed(authorizationStatus)
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
                    "Contacts -> turn on imessage-max. If it is not listed, run " +
                    "`imessage-max --request-contacts-access` once from a terminal."
            }
        }

        let (automationOk, automationStatus) = automationProbe()

        let overallStatus: DiagnoseStatus = dbOk && contactsAuthorized ? .ready : .needsSetup

        let automationFix = "Grant Automation access: System Settings -> Privacy & Security -> " +
            "Automation -> Enable Messages for your terminal app or the imessage-max executable"

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
                note: "The server cannot verify group file routing before the send. Check the delivered_to and chat fields in the response.")
            : automation

        let verifiedSend: Capability
        if !dbOk {
            verifiedSend = Capability(
                state: .permissionGated,
                fix: "Grant Full Disk Access so the server can re-read the database to verify each send.")
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
                note: "Requesting an offloaded file starts an iCloud download. Retry get_attachment after a few seconds.")
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
