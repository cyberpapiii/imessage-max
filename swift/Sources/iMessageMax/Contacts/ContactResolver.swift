// Sources/iMessageMax/Contacts/ContactResolver.swift
import Contacts
import Foundation

actor ContactResolver {
    /// Contacts access behind three closures so tests never touch
    /// CNContactStore (mirrors imsg's ContactCatalogSource). Closures run
    /// inside the actor; `@unchecked` for the same reason the old
    /// `nonisolated(unsafe) store` existed: CNContactStore is not Sendable.
    struct Source: @unchecked Sendable {
        let authorization: () -> (authorized: Bool, status: String)
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
    private var invalidated = false
    private var lastAuthorized = false
    private var hasLastGoodCache = false
    /// True when `initialize` returned early because `CI=true` was set.
    /// Surfaced by diagnose so an operator with CI exported in their shell
    /// can see why no names resolve.
    private var skippedForCI = false
    /// True when authorization was notDetermined and the policy said not to
    /// prompt. Surfaced by diagnose as `not_requested_headless`.
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

    init(seedCache: [String: String]) {
        self.init(
            source: Source(
                authorization: { (true, "authorized") },
                load: { seedCache },
                requestAccess: { true }
            ),
            refreshInterval: .infinity,
            now: { 0 },
            seedCache: seedCache
        )
    }

    init(
        source: Source,
        refreshInterval: TimeInterval,
        now: @escaping () -> TimeInterval,
        seedCache: [String: String]? = nil,
        observeChanges: Bool = false
    ) {
        self.source = source
        self.refreshInterval = refreshInterval
        self.now = now
        if let seedCache {
            self.cache = seedCache
            self.isInitialized = true
            self.lastAuthorized = true
            self.hasLastGoodCache = true
        }
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

    // MARK: - Authorization

    static func authorizationStatus() -> (authorized: Bool, status: String) {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized: return (true, "authorized")
        case .denied: return (false, "denied")
        case .restricted: return (false, "restricted")
        case .notDetermined: return (false, "not_determined")
        case .limited: return (true, "limited")
        @unknown default: return (false, "unknown")
        }
    }

    func requestAccessIfAllowed(policy: ContactsAccessPolicy) async {
        let (_, status) = source.authorization()
        guard status == "not_determined" else { return }
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

    // MARK: - Initialization

    func initialize() throws {
        // GitHub-hosted macos runners report Contacts as authorized, then
        // `enumerateContacts` talks to AddressBook over XPC. The daemon is
        // not running, so Core Data retries for minutes per call and
        // `swift test` never finishes (serial run 33573931260: one
        // list_attachments test took 298s, then the next never returned).
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            skippedForCI = true
            isInitialized = true
            return
        }

        let (authorized, _) = source.authorization()
        let expired = now() - loadedAt >= refreshInterval
        let authorizationChanged = authorized != lastAuthorized
        guard !isInitialized || invalidated || expired || authorizationChanged else { return }

        invalidated = false
        loadedAt = now()
        lastAuthorized = authorized
        isInitialized = true

        guard authorized else {
            // Revoked or never granted: never serve names we are no longer allowed to have.
            cache.removeAll()
            hasLastGoodCache = false
            return
        }
        do {
            cache = try source.load()
            hasLastGoodCache = true
        } catch {
            // Keep the last good cache; a transient AddressBook failure must
            // not fail five tools every 30 s. First-ever failure still throws
            // so diagnose can report `<status>_load_failed`.
            Log.warning("Contacts: refresh failed, keeping \(cache.count) cached names")
            if !hasLastGoodCache { throw error }
        }
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

    // MARK: - Resolution

    func resolve(_ handle: String) -> String? {
        if let name = cache[handle] { return name }
        if let normalized = PhoneUtils.normalizeToE164(handle),
           let name = cache[normalized]
        { return name }
        if handle.contains("@"),
           let name = cache[handle.lowercased()]
        { return name }
        return nil
    }

    /// Case-insensitive match on word starts ("jo" matches "John Smith" and "Mary Jo",
    /// not "Major"). Queries under two characters match nothing.
    func searchByName(_ query: String) -> [(handle: String, name: String)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return [] }
        let queryWords = q.split(separator: " ").map(String.init)
        return cache.compactMap { handle, name in
            let nameWords = name.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            let ok = queryWords.allSatisfy { qw in nameWords.contains { $0.hasPrefix(qw) } }
            return ok ? (handle, name) : nil
        }
    }

    func getStats() -> (initialized: Bool, handleCount: Int, skippedForCI: Bool, accessRequestSkippedHeadless: Bool) {
        (isInitialized, cache.count, skippedForCI, accessRequestSkippedHeadless)
    }
}
