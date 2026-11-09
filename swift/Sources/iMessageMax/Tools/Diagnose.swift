import Foundation
import IMessageMaxContract
import MCP

typealias DatabaseProbe = @Sendable () -> (ok: Bool, status: DatabaseStatus)

typealias UsageDescriptionProbe = @Sendable () -> Bool

typealias SchemaProbe = @Sendable () -> SchemaCapabilities?

typealias LiveInboxProbe = @Sendable () -> Bool

enum DiagnoseTool {
    static func definition(
        db: Database, resolver: ContactResolver, access: MessagesAccess, liveInbox: @escaping LiveInboxProbe
    ) -> ToolDefinition {
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
                A top-level status of "needs_setup" means the Messages database cannot be read, \
                so no tool works. Resolve it before you continue. Contacts and Automation do not \
                change the top-level status: check perm_contacts and the send capabilities. Use chat.name in user-facing \
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
                automationProbe: { await MessagesAccess.offPool { access.automationStatus() } },
                schemaProbe: { try? db.schema() },
                liveInboxProbe: liveInbox
            )
            return [.plainText(try FormatUtils.encodeJSON(result))]
        }
    }

    /// Who holds this process's privacy grants. macOS charges a helper inside
    /// an app bundle to that app, so its fixes name a permission in the app, not commands.
    enum GrantHolder: Equatable {
        case app(String)
        case executable(String)

        static var current: GrantHolder {
            GrantHolder(executable: Bundle.main.executablePath ?? CommandLine.arguments.first ?? ServiceDefaults.executableName)
        }

        init(executable: String) {
            let suffix = "/" + ServiceDefaults.helperBundlePath
            let app = executable.dropLast(suffix.count)
            if executable.hasSuffix(suffix), app.hasSuffix(".app") {
                self = .app((String(app) as NSString).abbreviatingWithTildeInPath)
            } else {
                self = .executable((executable as NSString).abbreviatingWithTildeInPath)
            }
        }

        var path: String {
            switch self {
            case .app(let path), .executable(let path): path
            }
        }
    }

    static func openStep(_ step: SetupStep) -> String {
        "Open iMessage Max and turn on \(step.title)."
    }

    /// The grant reaches only a new helper process, and the app restarts the
    /// helper itself when it opens again.
    static let appRechecks = "Then open iMessage Max again: it restarts its helper and checks by itself."

    static func fullDiskAccessFix(holder: GrantHolder = .current) -> String {
        switch holder {
        case .app(let app):
            return openStep(.fullDiskAccess)
                + " Then turn on iMessage Max (\(app)) in System Settings -> Privacy & Security -> "
                + "Full Disk Access. If it is already on there, turn it off and on again: "
                + "a grant made for an older copy of the app looks present but does not work. "
                + appRechecks
        case .executable(let executable):
            return "Full Disk Access is missing for the process reading chat.db (\(executable)). "
                + "1) System Settings -> Privacy & Security -> Full Disk Access -> add and turn on "
                + "this executable, or the app that launches it. "
                + "2) If it is already listed, toggle it off and on: a grant bound to an older "
                + "code signature looks present but does not work. "
                + "3) The grant applies only to newly launched processes; relaunch this server, "
                + "or reconnect the MCP client for stdio."
        }
    }

    static func missingUsageDescriptionFix(holder: GrantHolder) -> String {
        switch holder {
        case .app:
            "This copy of iMessage Max has no Contacts usage description, so macOS cannot ask for "
                + "or record a Contacts grant. Download iMessage Max again and replace this copy."
        case .executable:
            "This executable was built without its embedded Info.plist, so macOS cannot ask for "
                + "or record a Contacts grant for it. Use the helper inside iMessage Max instead. "
                + openStep(.contacts)
        }
    }

    static func contactsNotRequestedFix(holder: GrantHolder) -> String {
        switch holder {
        case .app:
            openStep(.contacts) + " The app asks macOS for Contacts on the helper's behalf, "
                + "because macOS does not let the helper ask on its own."
        case .executable(let executable):
            "This process (\(executable)) runs headless, so it did not ask for Contacts "
                + "access, and System Settings cannot add it to Contacts by hand. Use the helper "
                + "inside iMessage Max instead. " + openStep(.contacts)
        }
    }

    static func contactsDeniedFix(holder: GrantHolder) -> String {
        switch holder {
        case .app:
            openStep(.contacts)
                + " Then turn on iMessage Max in System Settings -> Privacy & Security -> Contacts. "
                + appRechecks
        case .executable(let executable):
            "Grant Contacts access: System Settings -> Privacy & Security -> Contacts -> "
                + "turn on imessage-max (\(executable)). If it is not listed, macOS never "
                + "recorded a request from it. Use the helper inside iMessage Max instead. "
                + openStep(.contacts)
        }
    }

    static func automationFix(holder: GrantHolder) -> String {
        switch holder {
        case .app:
            openStep(.automation)
                + " Then turn on Messages under iMessage Max in System Settings -> "
                + "Privacy & Security -> Automation."
        case .executable(let executable):
            "Grant Automation access: System Settings -> Privacy & Security -> Automation -> "
                + "turn on Messages under the app that launches this server, or under "
                + "imessage-max (\(executable)) when it runs on its own."
        }
    }

    /// Automation was never asked for. The helper never asks during a send,
    /// because nobody may be at the screen to answer, so the person sets it
    /// up once in the app, which asks while they watch.
    static func automationNotDeterminedFix(holder: GrantHolder) -> String {
        switch holder {
        case .app:
            openStep(.automation)
                + " macOS asks once, on this Mac's screen; click OK. Until then sends stop before "
                + "reaching Messages."
        case .executable(let executable):
            "macOS has not asked about Automation for Messages yet, and this process "
                + "(\(executable)) does not ask while nobody may be at the screen. Use the helper "
                + "inside iMessage Max instead. " + openStep(.automation)
        }
    }

    static let messagesNotRespondingNote =
        "Messages.app is running but did not answer within 2 s. Sends stop before reaching "
        + "Messages until it answers again."

    static func execute(
        resolver: ContactResolver,
        dbProbe: DatabaseProbe = { Database.checkAccess() },
        automationProbe: AutomationProbe,
        schemaProbe: SchemaProbe = { nil },
        liveInboxProbe: LiveInboxProbe = { false },
        usageDescriptionProbe: UsageDescriptionProbe = { ContactResolver.usageDescriptionEmbedded },
        holder: GrantHolder = .current,
        assistantCalls: @Sendable () -> Int = { ToolCallDispatch.assistantCalls.withLock { $0 } }
    ) async throws -> DiagnoseResult {
        let (dbOk, dbStatus) = dbProbe()
        let features = dbOk ? schemaProbe()?.features : nil

        var databaseFix: String? = nil
        if !dbOk {
            if dbStatus == .permissionDenied {
                databaseFix = fullDiskAccessFix(holder: holder)
            } else if dbStatus == .databaseNotFound {
                databaseFix = "iMessage database not found. Sign in to iMessage in Messages, then " +
                    "send or receive at least one message."
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
                contactsFix = missingUsageDescriptionFix(holder: holder)
            } else if authorizationStatus == .notDetermined, contacts.accessRequestSkippedHeadless {
                contactsStatus = .notRequestedHeadless
                contactsFix = contactsNotRequestedFix(holder: holder)
            } else {
                contactsFix = contactsDeniedFix(holder: holder)
            }
        }

        let (automationOk, automationStatus) = await automationProbe()

        // Only the database blocks every tool. Without Contacts names are
        // missing and without Automation sends stop; each shows in its own
        // capabilities, and a Mac that leaves Contacts off on purpose is ready.
        let overallStatus: DiagnoseStatus = dbOk ? .ready : .needsSetup

        let automation: Capability
        if automationOk {
            automation = Capability(state: .supported)
        } else if automationStatus == .denied {
            automation = Capability(state: .permissionGated, fix: automationFix(holder: holder))
        } else if automationStatus == .notDetermined {
            automation = Capability(state: .permissionGated, fix: automationNotDeterminedFix(holder: holder))
        } else if automationStatus == .messagesNotResponding {
            automation = Capability(state: .unverified, note: messagesNotRespondingNote)
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
            verifiedSend = Capability(state: .permissionGated, fix: databaseFix)
        } else if automationOk {
            verifiedSend = Capability(state: .supported, detail: "db_reread")
        } else {
            verifiedSend = Capability(state: .degraded)
        }

        let attachmentsRead = dbOk
            ? Capability(state: .supported)
            : Capability(state: .permissionGated, fix: databaseFix)
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
                state: automation.state, note: automation.note, fix: automation.fix,
                detail: automationStatus.rawValue),
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
            capabilities: Dictionary(uniqueKeysWithValues: capabilities.map { ($0.key.rawValue, $0.value) }),
            assistantCalls: assistantCalls()
        )
    }
}
