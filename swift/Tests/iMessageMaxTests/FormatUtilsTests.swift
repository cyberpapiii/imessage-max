import XCTest
@testable import iMessageMax

/// Pins the byte-for-byte output of `FormatUtils.encodeJSON`: important keys
/// first (in `orderedKeys` order), the rest alphabetically, minimal escaping
/// (`/`, U+2028 and non-ASCII pass through raw). Captured at commit 61e75d9.
/// Any change to this literal is a change to every tool response's shape and
/// must be deliberate.
final class FormatUtilsTests: XCTestCase {
    private struct GoldenAttachment: Encodable {
        let id: String
        let mime: String
        let size: Int
        let available: Bool
        let filename: String
    }

    private struct GoldenMessage: Encodable {
        let id: String
        let text: String
        let ts: String
        let from: String
        let reactions: [String]
        let media: GoldenAttachment?
        let zebra: String?
    }

    private struct GoldenResponse: Encodable {
        let messages: [GoldenMessage]
        let total: Int
        let more: Bool
        let cursor: String?
        let query: String
        let alpha: String
        let zulu: Double
        let ratio: Double
        let counts: [String: Int?]
        let nothing: String?
        let flags: [Bool]
    }

    private static let golden = GoldenResponse(
        messages: [
            GoldenMessage(
                id: "msg_1",
                text: "quote \" backslash \\ slash / newline\nTab\tEmoji 🎳 sep\u{2028}end",
                ts: "2026-09-01T10:00:00Z",
                from: "Alice",
                reactions: ["❤️ bob", "😂 nick"],
                media: GoldenAttachment(
                    id: "att_1",
                    mime: "image/jpeg",
                    size: 46080,
                    available: true,
                    filename: "IMG_0001.JPG"
                ),
                zebra: "last"
            ),
            GoldenMessage(
                id: "msg_2",
                text: "control \u{01} bell \u{07} backspace \u{08} formfeed \u{0C} cr \r",
                ts: "2026-09-01T10:05:00Z",
                from: "Bob",
                reactions: [],
                media: nil,
                zebra: nil
            ),
        ],
        total: 2,
        more: false,
        cursor: "abc/def",
        query: "hello",
        alpha: "first alphabetically",
        zulu: 3.0,
        ratio: 1.5,
        counts: ["a": 1, "b": nil],
        nothing: nil,
        flags: [true, false]
    )

    // Raw string: every backslash below is a literal byte of the JSON output.
    // `\#u{2028}` is the one interpolated escape (a raw U+2028 in the output).
    private static let expected = #"{"messages":[{"id":"msg_1","from":"Alice","text":"quote \" backslash \\ slash / newline\nTab\tEmoji 🎳 sep\#u{2028}end","ts":"2026-09-01T10:00:00Z","reactions":["❤️ bob","😂 nick"],"media":{"id":"att_1","available":true,"mime":"image/jpeg","size":46080,"filename":"IMG_0001.JPG"},"zebra":"last"},{"id":"msg_2","from":"Bob","text":"control \u0001 bell \u0007 backspace \b formfeed \f cr \r","ts":"2026-09-01T10:05:00Z","reactions":[]}],"total":2,"query":"hello","more":false,"cursor":"abc/def","alpha":"first alphabetically","counts":{"a":1,"b":null},"flags":[true,false],"ratio":1.5,"zulu":3}"#

    func testGoldenOrderingForNestedResponse() throws {
        let output = try FormatUtils.encodeJSON(Self.golden)
        XCTAssertEqual(output, Self.expected)
        // The literal above must itself be valid JSON, or the pin is meaningless.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(output.utf8)))
    }

    func testEncodeJSONObjectMatchesEncodableOrdering() throws {
        let object: [String: Any] = [
            "zebra": "z",
            "id": 7,
            "text": "t/\"\\",
            "nested": ["ts": "now", "aardvark": [1, 2.5, true, NSNull()]],
        ]
        XCTAssertEqual(
            try FormatUtils.encodeJSONObject(object),
            "{\"id\":7,\"text\":\"t/\\\"\\\\\",\"nested\":{\"ts\":\"now\",\"aardvark\":[1,2.5,true,null]},\"zebra\":\"z\"}"
        )
    }
}
