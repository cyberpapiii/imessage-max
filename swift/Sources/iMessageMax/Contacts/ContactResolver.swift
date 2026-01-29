// Sources/iMessageMax/Contacts/ContactResolver.swift
import Contacts
import Foundation

actor ContactResolver {
    private var cache: [String: String] = [:]  // handle -> name
    private var isInitialized = false
    // CNContactStore is not Sendable, so we mark it nonisolated(unsafe)
    // This is safe because we only use it from within actor-isolated methods
    nonisolated(unsafe) private let store = CNContactStore()

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

    func requestAccess() async throws -> Bool {
        try await store.requestAccess(for: .contacts)
    }

    // MARK: - Initialization

    func initialize() throws {
        guard !isInitialized else { return }

        let (authorized, _) = Self.authorizationStatus()
        guard authorized else {
            isInitialized = true
            return
        }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)

        try store.enumerateContacts(with: request) { contact, _ in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            guard !name.isEmpty else { return }

            // Map phone numbers using PhoneUtils
            for phone in contact.phoneNumbers {
                let number = phone.value.stringValue
                if let normalized = PhoneUtils.normalizeToE164(number) {
                    self.cache[normalized] = name
                }
            }

            // Map emails (lowercase)
            for email in contact.emailAddresses {
                let addr = (email.value as String).lowercased()
                self.cache[addr] = name
            }
        }

        isInitialized = true
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

    func searchByName(_ query: String) -> [(handle: String, name: String)] {
        let q = query.lowercased()
        return cache.compactMap { handle, name in
            name.lowercased().contains(q) ? (handle, name) : nil
        }
    }

    func getStats() -> (initialized: Bool, handleCount: Int) {
        (isInitialized, cache.count)
    }
}
