import Foundation

enum SetupPermission: String, Codable, Sendable { case contacts, automation }

struct SetupPermissionResult: Codable, Sendable {
    let permission: SetupPermission
    let authorized: Bool
    let status: String
    let processId: Int32

    enum CodingKeys: String, CodingKey {
        case permission, authorized, status
        case processId = "process_id"
    }
}

/// Permission requests must originate in the process that uses the grant.
/// A companion-spawned CLI inherits the companion's TCC responsibility and
/// cannot establish permission for the independently launchd-run service.
/// This service is used only by the explicit native setup route, never sends,
/// MCP tools, or startup. Ordinary headless starts remain non-prompting.
actor SetupPermissionService {
    typealias Request = @Sendable () async -> (ok: Bool, status: String)
    enum RequestError: Error { case alreadyRequesting }

    private let contactsRequest: Request
    private let automationRequest: Request
    private var requesting = false

    init(contactsRequest: @escaping Request, automationRequest: @escaping Request) {
        self.contactsRequest = contactsRequest
        self.automationRequest = automationRequest
    }

    init(resolver: ContactResolver) {
        contactsRequest = {
            await resolver.requestAccessIfAllowed(policy: .requestIfNeeded)
            let permission = ContactResolver.authorizationStatus()
            if permission.authorized {
                await resolver.invalidate()
                do { try await resolver.initialize() }
                catch { return (permission.authorized, "authorized_load_failed") }
            }
            return (permission.authorized, permission.status)
        }
        automationRequest = { await AutomationPermission.requestAccess() }
    }

    func request(_ permission: SetupPermission) async throws -> SetupPermissionResult {
        guard !requesting else { throw RequestError.alreadyRequesting }
        requesting = true
        defer { requesting = false }
        let result = await (permission == .contacts ? contactsRequest() : automationRequest())
        return SetupPermissionResult(permission: permission, authorized: result.ok, status: result.status, processId: getpid())
    }
}
