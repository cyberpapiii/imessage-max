import Contacts
import Foundation
import IMessageMaxContract

actor ContactResolver {
    struct Source: @unchecked Sendable {
        let authorization: () -> (authorized: Bool, status: PermissionStatus)
        let load: () throws -> [String: String]
        let requestAccess: () async -> Bool

        static func live(region: String?) -> Source {
            let store = CNContactStore()
            return Source(
                authorization: { ContactResolver.authorizationStatus() },
                load: { try ContactResolver.loadNames(from: store, region: region) },
                requestAccess: { (try? await store.requestAccess(for: .contacts)) ?? false }
            )
        }
    }

    private let source: Source
    /// The region that numbers without a country code are read in, for
    /// both Contacts numbers and the handles and numbers looked up.
    nonisolated let region: String?
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
    /// The reload running off the actor, if any. Requests keep using `cache`
    /// until it finishes and swaps the new names in.
    private var reloadTask: Task<Void, Never>?
    private var reloadAgain = false
    /// Bumped whenever the names are cleared, so a reload that began before
    /// access was revoked cannot put them back.
    private var generation = 0
    nonisolated(unsafe) private var changeObserver: (any NSObjectProtocol)?

    init(region: String? = PhoneUtils.currentRegion) {
        self.init(
            source: .live(region: region),
            refreshInterval: 30,
            now: { ProcessInfo.processInfo.systemUptime },
            observeChanges: true,
            region: region
        )
    }

    init(
        source: Source,
        refreshInterval: TimeInterval,
        now: @escaping () -> TimeInterval,
        observeChanges: Bool = false,
        region: String? = PhoneUtils.currentRegion
    ) {
        self.source = source
        self.region = region
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
            Log.info("Contacts: authorization is not determined and this process is headless, so it will not prompt. The diagnose tool names the fix.")
        }
    }

    func invalidate() {
        invalidated = true
    }

    /// Reloads the names when they are older than `refreshInterval`, when
    /// Contacts changed, or when access changed. Only the first load, which
    /// has nothing to answer with yet, runs on the request path. Every later
    /// one runs off the actor while requests use the last good names (088
    /// #26: a reload of 1.7k contacts held every request for about 0.5 s
    /// every 30 s). Revoked access clears the names at once.
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

        guard authorized else {
            generation += 1
            cache.removeAll()
            hasLastGoodCache = false
            lastLoadFailed = false
            return
        }
        if hasLastGoodCache {
            startBackgroundReload()
        } else {
            apply(Result { try source.load() })
        }
    }

    private func startBackgroundReload() {
        guard reloadTask == nil else {
            reloadAgain = true
            return
        }
        let source = source
        let generation = generation
        reloadTask = Task {
            let result = await withCheckedContinuation { continuation in
                Self.loadQueue.async { continuation.resume(returning: Result { try source.load() }) }
            }
            finishReload(result, generation: generation)
        }
    }

    private func finishReload(_ result: Result<[String: String], any Error>, generation: Int) {
        reloadTask = nil
        guard generation == self.generation, lastAuthorized else {
            reloadAgain = false
            return
        }
        apply(result)
        if reloadAgain {
            reloadAgain = false
            startBackgroundReload()
        }
    }

    private func apply(_ result: Result<[String: String], any Error>) {
        switch result {
        case .success(let names):
            cache = names
            hasLastGoodCache = true
            lastLoadFailed = false
        case .failure(let error):
            Log.warning("Contacts: refresh failed, keeping \(cache.count) cached names: \(error.localizedDescription)")
            lastLoadFailed = !hasLastGoodCache
        }
    }

    /// Contacts reads block, so they run here and never on a Swift
    /// concurrency thread.
    private static let loadQueue = DispatchQueue(label: "com.cyberpapiii.imessage-max.contacts-load", qos: .utility)

    /// Waits for a reload running off the actor. Tests use it to observe the
    /// swap.
    func waitForPendingReload() async {
        while let task = reloadTask {
            await task.value
        }
    }

    private func refreshIfStale() {
        guard invalidated || now() - checkedAt >= 1 else { return }
        refresh()
    }

    private static func loadNames(from store: CNContactStore, region: String?) throws -> [String: String] {
        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactNicknameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
        ].map { $0 as CNKeyDescriptor }
        var contacts: [CNContact] = []
        try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            contacts.append(contact)
        }
        return names(from: contacts, region: region)
    }

    /// Maps each phone number (E.164, read in `region`) and lowercased email
    /// of `contacts` to the contact's display name. A number that cannot be
    /// read without guessing is left out.
    static func names(from contacts: [CNContact], region: String?) -> [String: String] {
        var names: [String: String] = [:]
        for contact in contacts {
            guard let name = displayName(
                givenName: contact.givenName,
                familyName: contact.familyName,
                nickname: contact.nickname,
                organization: contact.organizationName
            ) else { continue }

            for phone in contact.phoneNumbers {
                if let normalized = PhoneUtils.normalizeToE164(phone.value.stringValue, region: region) {
                    names[normalized] = name
                }
            }

            for email in contact.emailAddresses {
                names[(email.value as String).lowercased()] = name
            }
        }
        return names
    }

    /// Given and family name, else the nickname, else the organization.
    static func displayName(givenName: String, familyName: String, nickname: String, organization: String) -> String? {
        let candidates = [
            [givenName, familyName]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " "),
            nickname.trimmingCharacters(in: .whitespacesAndNewlines),
            organization.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        return candidates.first { !$0.isEmpty }
    }

    func resolve(_ handle: String) -> String? {
        refreshIfStale()
        if let name = cache[handle] { return name }
        if let normalized = PhoneUtils.normalizeToE164(handle, region: region),
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
