import XCTest
@testable import iMessageMax

/// Times `FormatUtils.encodeJSON` on a synthetic `get_messages` page: 200
/// messages, each with six string fields, three participants, and a nested
/// attachment object. Plan 047 recorded before/after numbers in its commit.
final class EncodeJSONPerformanceTests: XCTestCase {
    private struct Participant: Encodable {
        let id: String
        let name: String
        let identity: String
    }

    private struct Attachment: Encodable {
        let id: String
        let mime: String
        let size: Int
        let size_human: String
        let available: Bool
        let filename: String
    }

    private struct Message: Encodable {
        let id: String
        let text: String
        let ts: String
        let ago: String
        let from: String
        let excerpt: String
        let participants: [Participant]
        let media: Attachment
    }

    private struct Page: Encodable {
        let messages: [Message]
        let total: Int
        let more: Bool
        let cursor: String
    }

    private static func makePage() -> Page {
        let messages = (0..<200).map { index in
            Message(
                id: "msg_\(index)",
                text: "Message number \(index) with a \"quote\", a slash / and an emoji 🎳 plus some\nnewline text to make the escape path do work.",
                ts: "2026-09-01T10:\(String(format: "%02d", index % 60)):00Z",
                ago: "\(index)m",
                from: index % 2 == 0 ? "Alice" : "Bob",
                excerpt: "Excerpt \(index) — short preview of the message body",
                participants: [
                    Participant(id: "p1", name: "Alice", identity: "+15555550001"),
                    Participant(id: "p2", name: "Bob", identity: "+15555550002"),
                    Participant(id: "p3", name: "Carol", identity: "carol@example.com"),
                ],
                media: Attachment(
                    id: "att_\(index)",
                    mime: "image/jpeg",
                    size: 46080 + index,
                    size_human: "45.0KB",
                    available: true,
                    filename: "IMG_\(index).JPG"
                )
            )
        }
        return Page(messages: messages, total: 200, more: true, cursor: "cursor_200")
    }

    func testEncodeSyntheticGetMessagesPage() throws {
        let page = Self.makePage()
        // Warm up once outside the measured block so the number is the steady state.
        _ = try FormatUtils.encodeJSON(page)
        measure {
            do {
                _ = try FormatUtils.encodeJSON(page)
            } catch {
                XCTFail("encodeJSON threw: \(error)")
            }
        }
    }
}
