import Foundation

enum ChatIdentifier {
    static func format(_ rowId: some BinaryInteger) -> String { "chat\(rowId)" }

    static func parseRowId(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasPrefix("chat") ? trimmed.dropFirst(4) : Substring(trimmed)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int64(digits)
    }
}

enum MessageIdentifier {
    static func format(_ rowId: some BinaryInteger) -> String { "msg_\(rowId)" }

    static func parse(_ raw: String) -> Int64? {
        if raw.hasPrefix("msg_") { return Int64(raw.dropFirst(4)) }
        if raw.hasPrefix("msg") { return Int64(raw.dropFirst(3)) }
        return Int64(raw)
    }
}

enum AttachmentIdentifier {
    static func format(_ rowId: some BinaryInteger) -> String { "att\(rowId)" }

    static func parse(_ raw: String) -> Int? {
        Int(raw.hasPrefix("att") ? raw.dropFirst(3) : Substring(raw))
    }
}
