import Foundation
import IMessageMaxContract

/// Permission requests must originate in the process that uses the grant.
/// A companion-spawned CLI inherits the companion's TCC responsibility and
/// cannot establish permission for the independently launchd-run service.
actor SetupPermissionService {
    typealias Request = @Sendable () async -> (ok: Bool, status: PermissionStatus)
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
            await resolver.invalidate()
            let contacts = await resolver.status()
            let status = contacts.authorization
            if contacts.authorized, contacts.loadFailed {
                return (true, .loadFailed(status))
            }
            return (contacts.authorized, status)
        }
        automationRequest = { await AutomationPermission.requestAccess() }
    }

    func request(_ permission: SetupPermission) async throws -> SetupPermissionReply {
        guard !requesting else { throw RequestError.alreadyRequesting }
        requesting = true
        defer { requesting = false }
        let result = await (permission == .contacts ? contactsRequest() : automationRequest())
        return SetupPermissionReply(permission: permission, authorized: result.ok, status: result.status, processID: getpid())
    }
}
