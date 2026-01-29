// Sources/iMessageMax/Contacts/PhoneUtils.swift
import Foundation

enum PhoneUtils {
    /// Normalize phone number to E.164 format (+1XXXXXXXXXX)
    static func normalizeToE164(_ input: String) -> String? {
        // Strip all non-digit characters except leading +
        let digits = input.filter { $0.isNumber }
        let hasPlus = input.hasPrefix("+")

        guard !digits.isEmpty else { return nil }

        // Handle US numbers
        if digits.count == 10 {
            // Assume US: add +1
            return "+1\(digits)"
        } else if digits.count == 11 && digits.hasPrefix("1") {
            // US with country code
            return "+\(digits)"
        } else if hasPlus {
            // International with +
            return "+\(digits)"
        } else if digits.count > 10 {
            // Assume international
            return "+\(digits)"
        }

        return nil
    }

    /// Format phone for display: +1 (555) 123-4567
    static func formatDisplay(_ phone: String) -> String {
        guard let normalized = normalizeToE164(phone) else {
            return phone
        }

        // Format US numbers
        if normalized.hasPrefix("+1") && normalized.count == 12 {
            let digits = String(normalized.dropFirst(2))
            let area = digits.prefix(3)
            let exchange = digits.dropFirst(3).prefix(3)
            let subscriber = digits.suffix(4)
            return "+1 (\(area)) \(exchange)-\(subscriber)"
        }

        return normalized
    }

    /// Check if string looks like a phone number
    static func isPhoneNumber(_ input: String) -> Bool {
        let digits = input.filter { $0.isNumber }
        return digits.count >= 10 && digits.count <= 15
    }

    /// Check if string is an email address
    static func isEmail(_ input: String) -> Bool {
        input.contains("@") && input.contains(".")
    }
}
