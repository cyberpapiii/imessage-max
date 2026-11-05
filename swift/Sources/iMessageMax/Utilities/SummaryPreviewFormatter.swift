import Foundation

enum SummaryPreviewFormatter {
    private static let linkDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let whitespaceRun = try! NSRegularExpression(pattern: "\\s+")
    private static let placeholderRun = try! NSRegularExpression(
        pattern: #"^(?:\[(?:Photo|Video|Audio|PDF|Attachment)\])+$"#)

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

    /// A text-less message's preview: "[Photo]", "[3 Photos]", or
    /// "[2 Attachments]" for mixed kinds.
    static func attachmentPlaceholder(for attachmentTypes: [AttachmentType]) -> String {
        summary(of: attachmentTypes, namingTwoKinds: false)
    }

    /// list_attachments' per-message summary: like `attachmentPlaceholder`,
    /// but two kinds are named in kind order, "[Photo, PDF]".
    static func sharedSummary(for attachmentTypes: [AttachmentType]) -> String {
        summary(of: attachmentTypes, namingTwoKinds: true)
    }

    private static func summary(of attachmentTypes: [AttachmentType], namingTwoKinds: Bool) -> String {
        guard let first = attachmentTypes.first else { return "[Attachment]" }
        if attachmentTypes.count == 1 {
            return singularPlaceholder(for: first)
        }

        let kinds = Set(attachmentTypes.map(\.rawValue)).sorted()
        if kinds.count == 1 {
            return "[\(attachmentTypes.count) \(pluralLabel(for: first))]"
        }
        if namingTwoKinds, kinds.count == 2 {
            let labels = kinds.compactMap(AttachmentType.init(rawValue:)).map {
                singularPlaceholder(for: $0).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            }
            return "[\(labels.joined(separator: ", "))]"
        }

        return "[\(attachmentTypes.count) Attachments]"
    }

    private static func singularPlaceholder(for type: AttachmentType) -> String {
        switch type {
        case .image:
            return MessageTextExtractor.photoPlaceholder
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
        guard let detector = linkDetector else {
            return text
        }

        var output = text
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        for match in detector.matches(in: output, range: range).reversed() {
            guard let swiftRange = Range(match.range, in: output) else { continue }
            let host = normalizedHost(for: match.url)
            output.replaceSubrange(swiftRange, with: "[Link: \(host)]")
        }

        let collapsedRange = NSRange(output.startIndex..<output.endIndex, in: output)
        return whitespaceRun
            .stringByReplacingMatches(in: output, options: [], range: collapsedRange, withTemplate: " ")
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
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let normalized = whitespaceRun.stringByReplacingMatches(
            in: text,
            options: [],
            range: fullRange,
            withTemplate: ""
        )
        let normalizedRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        return placeholderRun.firstMatch(in: normalized, options: [], range: normalizedRange) != nil
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength, maxLength > 3 else { return text }
        return String(text.prefix(maxLength - 3)) + "..."
    }
}
