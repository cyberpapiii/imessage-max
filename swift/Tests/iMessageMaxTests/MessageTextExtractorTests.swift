import Foundation
import XCTest
@testable import iMessageMax

final class MessageTextExtractorTests: XCTestCase {

    func testSingleByteLength() {
        let blob = typedstreamBlob(lengthField: [5], payload: Array("hello".utf8))
        XCTAssertEqual(MessageTextExtractor.extractFromTypedstream(blob), "hello")
    }

    func testTwoByteLength0x81() {
        let text = String(repeating: "a", count: 300)
        let blob = typedstreamBlob(lengthField: [0x81, 0x2C, 0x01], payload: Array(text.utf8))
        XCTAssertEqual(MessageTextExtractor.extractFromTypedstream(blob), text)
    }

    /// 0x82 carries a 4-byte length (088 #35). Reading 3 bytes left the
    /// fourth length byte at the start of the text, so text of 32 KB or more
    /// came back shifted by one byte, or as nil when that cut a character.
    func testFourByteLength0x82() {
        let text = String(repeating: "b", count: 70_000)
        let blob = typedstreamBlob(lengthField: [0x82, 0x70, 0x11, 0x01, 0x00], payload: Array(text.utf8))
        XCTAssertEqual(MessageTextExtractor.extractFromTypedstream(blob), text)
    }

    /// Each side of each width change: 127 fits in one byte, 128 to 32767
    /// take 0x81 and an int16, and 32768 up take 0x82 and an int32.
    func testLengthsAtEveryWidthBoundary() {
        for count in [1, 127, 128, 255, 256, 32_767, 32_768, 65_535, 65_536, 16_777_216] {
            let text = String(repeating: "x", count: count)
            let blob = typedstreamBlob(lengthField: typedstreamLength(count), payload: Array(text.utf8))
            XCTAssertEqual(MessageTextExtractor.extractFromTypedstream(blob)?.utf8.count, count, "length \(count)")
            XCTAssertEqual(MessageTextExtractor.extractFromTypedstream(blob), text, "length \(count)")
        }
    }

    /// Apple's own typedstream encoder (NSArchiver writes the format that
    /// message.attributedBody holds) at each width boundary. Marked
    /// deprecated only so the NSArchiver call compiles without a warning.
    @available(*, deprecated)
    func testAppleEncodedAttributedStringsAtEveryWidthBoundary() {
        for count in [5, 127, 128, 32_767, 32_768, 70_000] {
            let text = String(repeating: "x", count: count - 1) + "!"
            let blob = NSArchiver.archivedData(withRootObject: NSAttributedString(string: text))
            XCTAssertEqual(MessageTextExtractor.extractFromTypedstream(blob), text, "length \(count)")
        }
    }

    func testMultibyteTextPastTheInt16Limit() {
        let text = String(repeating: "é", count: 20_000) + "🎉"
        let payload = Array(text.utf8)
        XCTAssertGreaterThan(payload.count, 32_767)
        let blob = typedstreamBlob(lengthField: typedstreamLength(payload.count), payload: payload)
        XCTAssertEqual(MessageTextExtractor.extractFromTypedstream(blob), text)
    }

    func testTruncatedFourByteLengthReturnsNil() {
        var bytes: [UInt8] = [0x04, 0x0B]
        bytes += Array("NSString".utf8)
        bytes += [0x01, 0x94, 0x84, 0x01, 0x2B, 0x82, 0x00, 0x80, 0x00]
        XCTAssertNil(MessageTextExtractor.extractFromTypedstream(Data(bytes)))
    }

    private func typedstreamLength(_ count: Int) -> [UInt8] {
        let le = withUnsafeBytes(of: UInt32(count).littleEndian, Array.init)
        if count < 0x80 { return [UInt8(count)] }
        if count <= Int(Int16.max) { return [0x81] + le.prefix(2) }
        return [0x82] + le
    }

    func testNoMarkerReturnsNil() {
        let blob = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A])
        XCTAssertNil(MessageTextExtractor.extractFromTypedstream(blob))
    }

    func testTruncatedAfterMarkerReturnsNil() {
        var bytes: [UInt8] = [0x04, 0x0B]
        bytes += Array("NSString".utf8)
        bytes += [0x01, 0x2B]
        let blob = Data(bytes)
        XCTAssertNil(MessageTextExtractor.extractFromTypedstream(blob))
    }

    func testLengthOverrunReturnsNil() {
        let blob = typedstreamBlob(lengthField: [50], payload: Array(repeating: UInt8(0x41), count: 10))
        XCTAssertNil(MessageTextExtractor.extractFromTypedstream(blob))
    }

    func testInvalidUTF8ReturnsNil() {
        let blob = typedstreamBlob(lengthField: [2], payload: [0xFF, 0xFE])
        XCTAssertNil(MessageTextExtractor.extractFromTypedstream(blob))
    }

    func testExtractPrefersPlainText() {
        let blob = typedstreamBlob(lengthField: [5], payload: Array("hello".utf8))
        XCTAssertEqual(MessageTextExtractor.extract(text: "hi", attributedBody: blob), "hi")
    }

    func testExtractReplacesObjectReplacementChar() {
        XCTAssertEqual(
            MessageTextExtractor.extract(text: "a\u{FFFC}b", attributedBody: nil),
            "a[Photo]b"
        )
    }

    func testMutableStringMarkerAlsoParses() {
        let blob = typedstreamBlob(marker: "NSMutableString", lengthField: [5], payload: Array("hello".utf8))
        XCTAssertEqual(MessageTextExtractor.extractFromTypedstream(blob), "hello")
    }

    func testSliceInputDoesNotTrap() {
        let validBlob = typedstreamBlob(lengthField: [5], payload: Array("hello".utf8))
        let rebasedResult = MessageTextExtractor.extractFromTypedstream(Data(validBlob))

        var fullData = Data([0xAA, 0xBB, 0xCC, 0xDD])
        fullData.append(validBlob)
        let slice = fullData[4...]
        XCTAssertEqual(slice.startIndex, 4)

        let sliceResult = MessageTextExtractor.extractFromTypedstream(slice)
        XCTAssertEqual(sliceResult, rebasedResult)
        XCTAssertEqual(sliceResult, "hello")
    }

    func testUnknownMarker0x83ReturnsNil() {
        let blob = typedstreamBlob(
            lengthField: [0x83, 0x05, 0x00, 0x00, 0x00],
            payload: Array("hello".utf8)
        )
        XCTAssertNil(MessageTextExtractor.extractFromTypedstream(blob), "0x83 is an unrecognized marker, not a literal length of 131")
    }

    func testHighLiteralByteReturnsNil() {
        let blob = typedstreamBlob(lengthField: [0x9C], payload: Array(repeating: UInt8(0x41), count: 156))
        XCTAssertNil(MessageTextExtractor.extractFromTypedstream(blob))
    }
}
