import Foundation

enum SummaryPreviewFormatter {
    static func formattedTextPreview(
        text: String?,
        attributedBody: Data?,
        maxLength: Int
    ) -> String? {
        guard let extracted = MessageTextExtractor.extract(text: text, attributedBody: attributedBody)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !extracted.isEmpty
        else {
            return nil
        }

        if isSyntheticAttachmentPlaceholderText(extracted) {
            return nil
        }

        let collapsed = collapseURLs(in: extracted)
        return truncate(collapsed, maxLength: maxLength)
    }

    static func attachmentPlaceholder(for attachmentTypes: [AttachmentType]) -> String {
        guard !attachmentTypes.isEmpty else { return "[Attachment]" }

        if attachmentTypes.count == 1 {
            return singularPlaceholder(for: attachmentTypes[0])
        }

        let uniqueKinds = Set(attachmentTypes.map(\.rawValue))
        if uniqueKinds.count == 1, let first = attachmentTypes.first {
            return "[\(attachmentTypes.count) \(pluralLabel(for: first))]"
        }

        return "[\(attachmentTypes.count) Attachments]"
    }

    static func sharedSummary(for attachmentTypes: [AttachmentType]) -> String {
        guard !attachmentTypes.isEmpty else { return "[Attachment]" }
        if attachmentTypes.count == 1 {
            return singularPlaceholder(for: attachmentTypes[0])
        }

        let uniqueKinds = Array(Set(attachmentTypes.map(\.rawValue))).sorted()
        if uniqueKinds.count == 1, let first = attachmentTypes.first {
            return "[\(attachmentTypes.count) \(pluralLabel(for: first))]"
        }

        if uniqueKinds.count == 2 {
            let labels = uniqueKinds.compactMap { raw -> String? in
                guard let type = AttachmentType(rawValue: raw) else { return nil }
                return singularPlaceholder(for: type).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            }
            if labels.count == 2 {
                return "[\(labels.joined(separator: ", "))]"
            }
        }

        return "[\(attachmentTypes.count) Attachments]"
    }

    private static func singularPlaceholder(for type: AttachmentType) -> String {
        switch type {
        case .image:
            return "[Photo]"
        case .video:
            return "[Video]"
        case .audio:
            return "[Audio]"
        case .pdf:
            return "[PDF]"
        case .document, .other:
            return "[Attachment]"
        }
    }

    private static func pluralLabel(for type: AttachmentType) -> String {
        switch type {
        case .image:
            return "Photos"
        case .video:
            return "Videos"
        case .audio:
            return "Audio Files"
        case .pdf:
            return "PDFs"
        case .document, .other:
            return "Attachments"
        }
    }

    private static func collapseURLs(in text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text
        }

        var output = text
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        for match in detector.matches(in: output, range: range).reversed() {
            guard let swiftRange = Range(match.range, in: output) else { continue }
            let host = normalizedHost(for: match.url)
            output.replaceSubrange(swiftRange, with: "[Link: \(host)]")
        }

        return output
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedHost(for url: URL?) -> String {
        guard let host = url?.host, !host.isEmpty else { return "link" }
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }

    private static func isSyntheticAttachmentPlaceholderText(_ text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        let pattern = #"^(?:\[(?:Photo|Video|Audio|PDF|Attachment)\])+$"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength, maxLength > 3 else { return text }
        return String(text.prefix(maxLength - 3)) + "..."
    }
}
