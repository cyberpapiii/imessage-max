// Sources/iMessageMax/Contacts/PhoneUtils.swift
import Foundation

enum PhoneUtils {
    static func normalizeToE164(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.filter { $0.isNumber }
        let hasPlus = trimmed.hasPrefix("+")

        guard !digits.isEmpty, digits.count <= 15 else { return nil }

        // An explicit country code wins. "+45 12 34 56 78" is Danish, not a
        // US number missing its +1, even though it has 10 digits.
        if hasPlus {
            return "+\(digits)"
        }

        // No "+": assume the North American numbering plan for 10 digits, or
        // 11 digits starting with 1.
        if digits.count == 10 {
            return "+1\(digits)"
        }
        if digits.count == 11 && digits.hasPrefix("1") {
            return "+\(digits)"
        }
        if digits.count > 11 {
            // Long bare digit strings are international numbers typed without "+".
            return "+\(digits)"
        }

        return nil
    }

    static func formatDisplay(_ phone: String) -> String {
        guard let normalized = normalizeToE164(phone) else {
            return phone
        }

        if normalized.hasPrefix("+1") && normalized.count == 12 {
            let digits = String(normalized.dropFirst(2))
            let area = digits.prefix(3)
            let exchange = digits.dropFirst(3).prefix(3)
            let subscriber = digits.suffix(4)
            return "+1 (\(area)) \(exchange)-\(subscriber)"
        }

        return normalized
    }

    /// True for anything that could be a messaging handle made of digits:
    /// full numbers (10–15 digits) and carrier short codes (5–8 digits, no "+").
    static func isPhoneNumber(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.filter { $0.isNumber }
        let nonDigitsAllowed = trimmed.allSatisfy { $0.isNumber || " -()+.".contains($0) }
        guard nonDigitsAllowed else { return false }
        if digits.count >= 10 && digits.count <= 15 { return true }
        return !trimmed.hasPrefix("+") && digits.count >= 5 && digits.count <= 8
    }

    static func isEmail(_ input: String) -> Bool {
        input.contains("@") && input.contains(".")
    }
}
