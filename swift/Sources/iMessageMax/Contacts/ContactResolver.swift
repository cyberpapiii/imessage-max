import Contacts
import Foundation
import IMessageMaxContract

actor ContactResolver {
    struct Source: @unchecked Sendable {
        let authorization: () -> (authorized: Bool, status: PermissionStatus)
        let load: () throws -> [String: String]
        let requestAccess: () async -> Bool

        static func live() -> Source {
            let store = CNContactStore()
            return Source(
                authorization: { ContactResolver.authorizationStatus() },
                load: { try ContactResolver.loadNames(from: store) },
                requestAccess: { (try? await store.requestAccess(for: .contacts)) ?? false }
            )
        }
    }

    private let source: Source
    private let refreshInterval: TimeInterval
    private let now: () -> TimeInterval

    private var cache: [String: String] = [:]
    private var isInitialized = false
    private var loadedAt: TimeInterval = -.infinity
    private var checkedAt: TimeInterval = -.infinity
    private var invalidated = false
    private var lastAuthorized = false
    private var hasLastGoodCache = false
    private var lastLoadFailed = false
    private var accessRequestSkippedHeadless = false
    nonisolated(unsafe) private var changeObserver: (any NSObjectProtocol)?

    init() {
        self.init(
            source: .live(),
            refreshInterval: 30,
            now: { ProcessInfo.processInfo.systemUptime },
            observeChanges: true
        )
    }

    init(
        source: Source,
        refreshInterval: TimeInterval,
        now: @escaping () -> TimeInterval,
        observeChanges: Bool = false
    ) {
        self.source = source
        self.refreshInterval = refreshInterval
        self.now = now
        if observeChanges {
            changeObserver = NotificationCenter.default.addObserver(
                forName: .CNContactStoreDidChange, object: nil, queue: nil
            ) { [weak self] _ in
                Task { await self?.invalidate() }
            }
        }
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    private static func authorizationStatus() -> (authorized: Bool, status: PermissionStatus) {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized: return (true, .authorized)
        case .denied: return (false, .denied)
        case .restricted: return (false, .restricted)
        case .notDetermined: return (false, .notDetermined)
        case .limited: return (true, .limited)
        @unknown default: return (false, .unknown)
        }
    }

    /// macOS will neither prompt nor record a Contacts grant for an
    /// executable without NSContactsUsageDescription. A bare `swift build`
    /// links without the embedded Info.plist; `make build` adds it.
    static var usageDescriptionEmbedded: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil
    }

    func authorization() -> (authorized: Bool, status: PermissionStatus) {
        source.authorization()
    }

    func requestAccessIfAllowed(policy: ContactsAccessPolicy) async {
        let (_, status) = source.authorization()
        guard status == .notDetermined else { return }
        switch policy {
        case .requestIfNeeded:
            let granted = await source.requestAccess()
            Log.info("Contacts: authorization requested, granted=\(granted)")
        case .skipIfNotDetermined:
            accessRequestSkippedHeadless = true
            Log.info("Contacts: authorization not determined and this process is headless; not prompting. Run `imessage-max --request-contacts-access` from a terminal once, then restart the service.")
        }
    }

    func invalidate() {
        invalidated = true
    }

    private func refresh() {
        checkedAt = now()
        let (authorized, _) = source.authorization()
        let expired = now() - loadedAt >= refreshInterval
        let authorizationChanged = authorized != lastAuthorized
        guard !isInitialized || invalidated || expired || authorizationChanged else { return }

        invalidated = false
        loadedAt = now()
        lastAuthorized = authorized
        isInitialized = true
        lastLoadFailed = false

        guard authorized else {
            cache.removeAll()
            hasLastGoodCache = false
            return
        }
        do {
            cache = try source.load()
            hasLastGoodCache = true
        } catch {
            Log.warning("Contacts: refresh failed, keeping \(cache.count) cached names: \(error.localizedDescription)")
            if !hasLastGoodCache {
                lastLoadFailed = true
            }
        }
    }

    private func refreshIfStale() {
        guard invalidated || now() - checkedAt >= 1 else { return }
        refresh()
    }

    private static func loadNames(from store: CNContactStore) throws -> [String: String] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        var names: [String: String] = [:]

        try store.enumerateContacts(with: request) { contact, _ in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            guard !name.isEmpty else { return }

            for phone in contact.phoneNumbers {
                let number = phone.value.stringValue
                if let normalized = PhoneUtils.normalizeToE164(number) {
                    names[normalized] = name
                }
            }

            for email in contact.emailAddresses {
                let addr = (email.value as String).lowercased()
                names[addr] = name
            }
        }

        return names
    }

    func resolve(_ handle: String) -> String? {
        refreshIfStale()
        if let name = cache[handle] { return name }
        if let normalized = PhoneUtils.normalizeToE164(handle),
           let name = cache[normalized]
        { return name }
        if handle.contains("@"),
           let name = cache[handle.lowercased()]
        { return name }
        return nil
    }

    func searchByName(_ query: String) -> [(handle: String, name: String)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return [] }
        refreshIfStale()
        let queryWords = q.split(separator: " ").map(String.init)
        return cache.compactMap { handle, name in
            let nameWords = name.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            let ok = queryWords.allSatisfy { qw in nameWords.contains { $0.hasPrefix(qw) } }
            return ok ? (handle, name) : nil
        }
        .sorted { ($0.name, $0.handle) < ($1.name, $1.handle) }
    }

    struct Status: Sendable {
        let authorized: Bool
        let authorization: PermissionStatus
        let handleCount: Int
        let loadFailed: Bool
        let accessRequestSkippedHeadless: Bool
    }

    func status() -> Status {
        refresh()
        let (authorized, authorization) = source.authorization()
        return Status(
            authorized: authorized,
            authorization: authorization,
            handleCount: cache.count,
            loadFailed: lastLoadFailed,
            accessRequestSkippedHeadless: accessRequestSkippedHeadless
        )
    }
}
