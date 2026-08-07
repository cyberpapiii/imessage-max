// Sources/iMessageMax/Contacts/PhoneUtils.swift
import Foundation

enum PhoneUtils {
    static func normalizeToE164(_ input: String) -> String? {
        let digits = input.filter { $0.isNumber }
        let hasPlus = input.hasPrefix("+")

        guard !digits.isEmpty else { return nil }

        if digits.count == 10 {
            return "+1\(digits)"
        } else if digits.count == 11 && digits.hasPrefix("1") {
            return "+\(digits)"
        } else if hasPlus {
            return "+\(digits)"
        } else if digits.count > 10 {
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

    static func isPhoneNumber(_ input: String) -> Bool {
        let digits = input.filter { $0.isNumber }
        return digits.count >= 10 && digits.count <= 15
    }

    static func isEmail(_ input: String) -> Bool {
        input.contains("@") && input.contains(".")
    }
}
