import AppKit
import CoreText
import XCTest
@testable import iMessageMax

final class DocumentAttachmentTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func fetch(
        _ data: Data,
        name: String,
        mimeType: String?,
        uti: String,
        variant: String = "vision",
        text: TextRequest = TextRequest()
    ) async throws -> AttachmentReply {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        files.append(url)
        let fixture = try ToolTestDatabase(name: "document-\(name)")
        try fixture.insertAttachment(rowId: 5, filename: url.path, mimeType: mimeType, uti: uti, totalBytes: data.count, transferName: name)
        let tool = GetAttachment(db: fixture.database(), resolver: ContactResolver(seedCache: [:]))
        return try attachmentReply(try await tool.execute(
            attachmentId: "att5", variant: variant, text: text,
            allowedRoots: [FileManager.default.temporaryDirectory.path]
        ))
    }

    func testPDFReturnsItsTextWithPageMarkers() async throws {
        let pdf = makePDF(pages: ["Lease agreement for unit 4B", "Rent is due on the first of the month"])
        let reply = try await fetch(pdf, name: "lease.pdf", mimeType: "application/pdf", uti: "com.adobe.pdf")

        XCTAssertEqual(reply.metadata["type"] as? String, "pdf")
        XCTAssertEqual(reply.metadata["pages"] as? Int, 2)
        XCTAssertNil(reply.metadata["next_offset"], "a short PDF fits in one reply")
        XCTAssertTrue(reply.images.isEmpty)
        let text = try XCTUnwrap(reply.texts.first)
        XCTAssertEqual(reply.texts.count, 1)
        XCTAssertTrue(text.contains("[page 1]\nLease agreement for unit 4B"), text)
        XCTAssertTrue(text.contains("[page 2]\nRent is due on the first of the month"), text)
        XCTAssertEqual(reply.metadata["chars"] as? Int, text.count)
    }

    func testScannedPDFReturnsImagesOfItsFirstPages() async throws {
        let pdf = makePDF(pages: Array(repeating: nil, count: 5))
        let reply = try await fetch(pdf, name: "scan.pdf", mimeType: "application/pdf", uti: "com.adobe.pdf", variant: "thumb")

        XCTAssertEqual(reply.metadata["pages"] as? Int, 5)
        XCTAssertEqual(reply.metadata["chars"] as? Int, 0)
        XCTAssertEqual(reply.metadata["rendered_pages"] as? Int, GetAttachment.scannedPagesShown)
        XCTAssertTrue(reply.texts.isEmpty)
        XCTAssertEqual(reply.images.count, GetAttachment.scannedPagesShown)
        for image in reply.images {
            XCTAssertEqual(image.mimeType, "image/jpeg")
            let source = try XCTUnwrap(CGImageSourceCreateWithData(image.data as CFData, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let longSide = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
            XCTAssertEqual(longSide, 400, "thumb renders a page at 400px on its long side")
        }
    }

    func testLongTextIsServedInWindowsThatJoinBackToTheWhole() async throws {
        let paragraph = (1...400).map { "Line \($0) of the meeting notes." }.joined(separator: "\n")
        var pieces: [String] = []
        var offset = 0
        while true {
            let reply = try await fetch(
                Data(paragraph.utf8), name: "notes.txt", mimeType: "text/plain", uti: "public.plain-text",
                text: TextRequest(offset: offset, maxChars: 1_000)
            )
            XCTAssertEqual(reply.metadata["chars"] as? Int, paragraph.count)
            XCTAssertEqual(reply.metadata["offset"] as? Int, offset == 0 ? nil : offset)
            let text = try XCTUnwrap(reply.texts.first)
            XCTAssertLessThanOrEqual(text.count, 1_000)
            pieces.append(text)
            guard let next = reply.metadata["next_offset"] as? Int else { break }
            XCTAssertTrue(text.hasSuffix("\n"), "a window ends at a line break when one is close")
            offset = next
        }
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.joined(), paragraph, "reading on with next_offset loses and repeats nothing")
    }

    func testOffsetPastTheEndIsAValidationError() async throws {
        let body = try await toolFailureBody {
            try await self.fetch(Data("short".utf8), name: "short.txt", mimeType: "text/plain", uti: "public.plain-text", text: TextRequest(offset: 50))
        }
        XCTAssertEqual(body["error"] as? String, "validation_error")
    }

    func testRichTextAndWordDocumentsReturnTheirText() async throws {
        let body = NSAttributedString(string: "Packing list: tent, stove, two headlamps", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let cases: [(name: String, mime: String, uti: String, type: NSAttributedString.DocumentType)] = [
            ("list.rtf", "text/rtf", "public.rtf", .rtf),
            ("list.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "org.openxmlformats.wordprocessingml.document", .officeOpenXML),
            ("list.doc", "application/msword", "com.microsoft.word.doc", .docFormat),
            ("list.odt", "application/vnd.oasis.opendocument.text", "org.oasis-open.opendocument.text", .openDocument),
        ]
        for item in cases {
            let data = try body.data(from: NSRange(location: 0, length: body.length), documentAttributes: [.documentType: item.type])
            let reply = try await fetch(data, name: item.name, mimeType: item.mime, uti: item.uti)
            XCTAssertEqual(reply.texts.first?.trimmingCharacters(in: .whitespacesAndNewlines), body.string, item.name)
            XCTAssertNil(reply.metadata["pages"], "\(item.name) has no pages")
        }
    }

    func testExtensionIdentifiesAFileWhoseUTIIsUnknown() async throws {
        let reply = try await fetch(Data("name,amount\nrent,1200\n".utf8), name: "budget.csv", mimeType: nil, uti: "dyn.unknown")
        XCTAssertEqual(reply.texts.first, "name,amount\nrent,1200\n")
    }

    func testSpreadsheetIsStillUnsupported() async throws {
        let body = try await toolFailureBody {
            try await self.fetch(Data("PK".utf8), name: "sheet.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", uti: "org.openxmlformats.spreadsheetml.sheet")
        }
        XCTAssertEqual(body["error"] as? String, "unsupported_type")
        XCTAssertEqual(body["type"] as? String, "document")
        XCTAssertEqual(body["filename"] as? String, "sheet.xlsx")
    }
}

/// A PDF whose pages hold one line of text each, or, for a nil page, only a
/// filled rectangle, like a scan with no text layer.
private func makePDF(pages: [String?]) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
    for page in pages {
        context.beginPDFPage(nil)
        if let page {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: page, attributes: [.font: NSFont.systemFont(ofSize: 18)]))
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
        } else {
            context.setFillColor(gray: 0.3, alpha: 1)
            context.fill(CGRect(x: 72, y: 72, width: 468, height: 648))
        }
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}
