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

    func testThreeByteLength0x82() {
        let text = String(repeating: "b", count: 70_000)
        let blob = typedstreamBlob(lengthField: [0x82, 0x70, 0x11, 0x01], payload: Array(text.utf8))
        XCTAssertEqual(MessageTextExtractor.extractFromTypedstream(blob), text)
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
