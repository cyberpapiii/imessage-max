import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// The text of a PDF or document attachment, read on this Mac with no
/// permission beyond Full Disk Access.
enum DocumentText {
    enum Format {
        case pdf
        case plain
        case rich(NSAttributedString.DocumentType)
    }

    struct Extracted {
        let text: String
        /// Set for a PDF.
        let pages: Int?
    }

    /// Plain and rich files are read whole, so a larger one is refused.
    static let maxReadBytes = 32 * 1024 * 1024

    /// Messages records a UTI for most attachments; the file extension covers the rest.
    static func format(uti: String?, path: String) -> Format? {
        let candidates = [uti.flatMap(UTType.init), UTType(filenameExtension: (path as NSString).pathExtension)]
        return candidates.lazy.compactMap { $0.flatMap(format(of:)) }.first
    }

    private static func format(of type: UTType) -> Format? {
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD) { return .rich(.rtfd) }
        if type.conforms(to: .rtf) { return .rich(.rtf) }
        if let rich = richTypes.first(where: { type.conforms(to: $0.type) }) { return .rich(rich.format) }
        // public.text covers plain text, source code, CSV, JSON, HTML and
        // contact cards. HTML comes back as its source: rendering it could
        // load remote content.
        if type.conforms(to: .text) { return .plain }
        return nil
    }

    private static let richTypes: [(type: UTType, format: NSAttributedString.DocumentType)] = [
        (UTType("org.openxmlformats.wordprocessingml.document"), .officeOpenXML),
        (UTType("com.microsoft.word.doc"), .docFormat),
        (UTType("org.oasis-open.opendocument.text"), .openDocument),
    ].compactMap { type, format in type.map { ($0, format) } }

    static func extract(path: String, format: Format) throws -> Extracted {
        let url = URL(fileURLWithPath: path)
        switch format {
        case .pdf:
            guard let document = PDFDocument(url: url) else {
                throw ToolFailure("processing_failed", "The PDF could not be opened")
            }
            guard !document.isLocked else {
                throw ToolFailure("processing_failed", "The PDF is password protected")
            }
            let pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
            let text = pages.count == 1
                ? pages[0]
                : pages.enumerated().map { "[page \($0.offset + 1)]\n\($0.element)" }.joined(separator: "\n\n")
            let hasText = pages.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return Extracted(text: hasText ? text : "", pages: document.pageCount)

        case .plain:
            try checkSize(url)
            var encoding = String.Encoding.utf8
            let text = try (try? String(contentsOf: url, usedEncoding: &encoding)) ?? String(decoding: Data(contentsOf: url), as: UTF8.self)
            return Extracted(text: text, pages: nil)

        case .rich(let documentType):
            try checkSize(url)
            do {
                let string = try NSAttributedString(url: url, options: [.documentType: documentType], documentAttributes: nil)
                return Extracted(text: string.string, pages: nil)
            } catch {
                throw ToolFailure("processing_failed", "The document could not be read")
            }
        }
    }

    private static func checkSize(_ url: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxReadBytes else {
            throw ToolFailure("processing_failed", "The document is larger than \(maxReadBytes / 1024 / 1024) MB, so its text is not read")
        }
    }

    /// Renders the first pages of a PDF with no text layer, such as a scan,
    /// so a model can read them as images.
    static func renderPages(path: String, maxPages: Int, maxDimension: Int) -> [CGImage] {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)), !document.isLocked else { return [] }
        return (0..<min(maxPages, document.pageCount)).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            let scale = CGFloat(maxDimension) / max(bounds.width, bounds.height, 1)
            let width = max(1, Int((bounds.width * scale).rounded()))
            let height = max(1, Int((bounds.height * scale).rounded()))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
            return context.makeImage()
        }
    }
}

/// Which window of a document's text a get_attachment call asks for.
struct TextRequest {
    static let offsetArgument = IntArgument(name: "offset", defaultValue: 0, range: 0...Int(Int32.max))
    static let maxCharsArgument = IntArgument(name: "max_chars", defaultValue: 10_000, range: 1_000...50_000)

    var offset = TextRequest.offsetArgument.defaultValue
    var maxChars = TextRequest.maxCharsArgument.defaultValue
}

/// One window of a document's text, and where the next one starts.
struct TextWindow: Encodable, Sendable {
    let pages: Int?
    let chars: Int
    let offset: Int?
    let nextOffset: Int?
    let renderedPages: Int?

    private enum CodingKeys: String, CodingKey {
        case pages, chars, offset
        case nextOffset = "next_offset"
        case renderedPages = "rendered_pages"
    }

    /// Cuts `text` to at most `maxChars` characters from `offset`, ending at a
    /// line or word break when one is close.
    static func cut(_ text: String, offset: Int, maxChars: Int, pages: Int?) throws -> (window: TextWindow, text: String) {
        let total = text.count
        guard offset == 0 || offset < total else {
            throw ToolFailure("validation_error", "offset \(offset) is past the end of the text (\(total) characters)")
        }
        let start = text.index(text.startIndex, offsetBy: offset)
        var end = text.index(start, offsetBy: maxChars, limitedBy: text.endIndex) ?? text.endIndex
        if end < text.endIndex {
            let floor = text.index(start, offsetBy: maxChars * 4 / 5)
            let tail = text[floor..<end]
            if let breakIndex = tail.lastIndex(where: \.isNewline) ?? tail.lastIndex(of: " ") {
                end = text.index(after: breakIndex)
            }
        }
        let next = end < text.endIndex ? offset + text.distance(from: start, to: end) : nil
        let window = TextWindow(pages: pages, chars: total, offset: offset > 0 ? offset : nil, nextOffset: next, renderedPages: nil)
        return (window, String(text[start..<end]))
    }
}
