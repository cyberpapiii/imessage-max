import XCTest
@testable import iMessageMax

final class SummaryPreviewFormatterTests: XCTestCase {
    func testCollapsesLinksAndWhitespace() {
        let preview = SummaryPreviewFormatter.formattedTextPreview(
            text: "see  https://www.example.com/x\n\nnow",
            attributedBody: nil,
            maxLength: 200
        )
        XCTAssertEqual(preview, "see [Link: example.com] now")
    }

    func testSyntheticPlaceholderIsNil() {
        XCTAssertNil(
            SummaryPreviewFormatter.formattedTextPreview(
                text: "[Photo] [Video]",
                attributedBody: nil,
                maxLength: 200
            )
        )
        XCTAssertNotNil(
            SummaryPreviewFormatter.formattedTextPreview(
                text: "[Photo] and text",
                attributedBody: nil,
                maxLength: 200
            )
        )
    }

    func testTruncateAppendsEllipsis() throws {
        let text = String(repeating: "x", count: 200)
        let preview = try XCTUnwrap(
            SummaryPreviewFormatter.formattedTextPreview(
                text: text,
                attributedBody: nil,
                maxLength: 50
            )
        )
        XCTAssertEqual(preview.count, 50)
        XCTAssertTrue(preview.hasSuffix("..."))
    }

    func testMakeExcerptCentresOnFirstMatch() {
        let text = String(repeating: "a", count: 600) + "needle" + String(repeating: "b", count: 400)
        let excerpt = SearchTool.makeExcerpt(text: text, query: "needle")
        XCTAssertTrue(excerpt.hasPrefix("..."))
        XCTAssertTrue(excerpt.contains("needle"))
        XCTAssertEqual(excerpt.count, 3 + 160 + 3)
    }

    func testMakeExcerptWithoutQueryTakesHead() {
        let text = String(repeating: "c", count: 500)
        let excerpt = SearchTool.makeExcerpt(text: text, query: nil)
        XCTAssertEqual(excerpt, String(repeating: "c", count: 160) + "...")
    }

    func testMakeExcerptWithLinkStraddlingTheCut() {
        let text = String(repeating: "x", count: 700)
            + " "
            + "https://www.example.com/path"
            + String(repeating: "y", count: 300)
        let excerpt = SearchTool.makeExcerpt(text: text, query: "y")
        XCTAssertEqual(
            excerpt,
            "..."
                + String(repeating: "x", count: 55)
                + " [Link: example.com]/path"
                + String(repeating: "y", count: 80)
                + "..."
        )
    }
}
