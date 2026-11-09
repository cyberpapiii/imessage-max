import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import iMessageMax

final class GetAttachmentToolTests: XCTestCase {
    func testThumbVariantHonorsMaxDimensionAndDoesNotUpscale() throws {
        let processor = ImageProcessor()

        let largeURL = try makeFixtureImage(name: "thumb-large.jpg", width: 2000, height: 1000)
        defer { try? FileManager.default.removeItem(at: largeURL) }
        let largeResult = try XCTUnwrap(processor.process(at: largeURL.path, variant: .thumb))
        XCTAssertLessThanOrEqual(largeResult.width, 400)
        XCTAssertLessThanOrEqual(largeResult.height, 400)
        XCTAssertEqual(largeResult.width, 400)
        XCTAssertEqual(largeResult.height, 200)

        let smallURL = try makeFixtureImage(name: "thumb-small.jpg", width: 100, height: 50)
        defer { try? FileManager.default.removeItem(at: smallURL) }
        let smallResult = try XCTUnwrap(processor.process(at: smallURL.path, variant: .thumb))
        XCTAssertEqual(smallResult.width, 100, "Images smaller than maxDimension must not be upscaled")
        XCTAssertEqual(smallResult.height, 50, "Images smaller than maxDimension must not be upscaled")
    }

    func testDeclaredOversizeTripsTheFullVariantPixelCap() throws {
        let declaredWidth = 8000
        let declaredHeight = ImageProcessor.maxFullVariantPixels / declaredWidth + 1
        XCTAssertGreaterThan(declaredWidth * declaredHeight, ImageProcessor.maxFullVariantPixels)

        let oversizedURL = try makeJPEGDeclaringDimensions(
            pixelWidth: 200,
            pixelHeight: 100,
            declaredWidth: declaredWidth,
            declaredHeight: declaredHeight,
            name: "full-oversize.jpg"
        )
        defer { try? FileManager.default.removeItem(at: oversizedURL) }

        XCTAssertTrue(
            ImageProcessor.exceedsFullVariantPixels(at: oversizedURL),
            "SOF-declared oversize must trip the pixel cap so process(.full) never decodes"
        )
    }

    func testProcessedOutputIsJPEG() throws {
        let imageURL = try makeFixtureImage(name: "jpeg-format.jpg", width: 800, height: 600)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let processor = ImageProcessor()
        let result = try XCTUnwrap(processor.process(at: imageURL.path, variant: .vision))
        XCTAssertEqual(result.format, "jpeg")
        XCTAssertGreaterThanOrEqual(result.data.count, 2)
        XCTAssertEqual(Array(result.data.prefix(2)), [0xFF, 0xD8], "Output must start with the JPEG magic bytes")
    }

    func testExecuteReturnsResizedImageForVisionVariant() async throws {
        let imageURL = try makeFixtureImage(name: "attachment-large.jpg", width: 2000, height: 1000)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let fixture = try ToolTestDatabase(name: "get-attachment-vision")
        try fixture.insertAttachment(rowId: 1, filename: imageURL.path, mimeType: "image/jpeg", uti: "public.jpeg", transferName: "attachment-large.jpg")

        let tool = GetAttachment(db: fixture.database(), resolver: ContactResolver(seedCache: [:]))
        let reply = try attachmentReply(try await tool.execute(attachmentId: "att1", variant: "vision", allowedRoots: [FileManager.default.temporaryDirectory.path]))

        XCTAssertEqual(reply.metadata["id"] as? String, "att1")
        XCTAssertEqual(reply.metadata["type"] as? String, "image")
        XCTAssertEqual(reply.metadata["name"] as? String, "attachment-large.jpg")
        XCTAssertEqual(reply.metadata["available"] as? Bool, true)
        XCTAssertEqual(reply.images.count, 1)
        XCTAssertTrue(reply.texts.isEmpty)
        let (jpeg, mimeType) = try XCTUnwrap(reply.images.first)
        XCTAssertEqual(mimeType, "image/jpeg")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1568, "vision caps the long side at 1568")
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 784)
    }

    func testUnnamedDMChatNameUsesResolvedParticipant() async throws {
        let imageURL = try makeFixtureImage(name: "unnamed-dm.jpg", width: 200, height: 100)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let fixture = try ToolTestDatabase(name: "get-attachment-unnamed-dm")
        try fixture.insertHandle(rowId: 1, handle: "+15550000022")
        try fixture.insertChat(rowId: 22, guid: "imessage-sukhmani", displayName: nil)
        try fixture.joinChatHandle(chatId: 22, handleId: 1)
        try fixture.insertMessage(
            rowId: 1,
            guid: "msg-1",
            text: nil,
            date: 1_000_000_000,
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 22, messageId: 1)
        try fixture.insertAttachment(
            rowId: 7,
            filename: imageURL.path,
            mimeType: "image/jpeg",
            uti: "public.jpeg",
            transferName: "photo.jpg"
        )
        try fixture.joinMessageAttachment(messageId: 1, attachmentId: 7)

        let tool = GetAttachment(
            db: fixture.database(),
            resolver: ContactResolver(seedCache: ["+15550000022": "Sukhmani Kular"])
        )
        let reply = try attachmentReply(try await tool.execute(
            attachmentId: "att7",
            variant: "thumb",
            allowedRoots: [FileManager.default.temporaryDirectory.path]
        ))
        let chat = try XCTUnwrap(reply.metadata["chat"] as? [String: Any])

        XCTAssertEqual(chat["id"] as? String, "chat22")
        XCTAssertEqual(
            chat["name"] as? String,
            "Sukhmani Kular",
            "Unnamed DM should use the resolved participant name, not chat{rowid}"
        )
    }

    func testExecuteReturnsOffloadedErrorWhenImageFileIsMissing() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-missing-attachment.jpg").path

        let fixture = try ToolTestDatabase(name: "get-attachment-missing")
        try fixture.insertAttachment(rowId: 3, filename: missingPath, mimeType: "image/jpeg", uti: "public.jpeg", totalBytes: 12, transferName: "missing.jpg")

        let tool = GetAttachment(db: fixture.database(), resolver: ContactResolver(seedCache: [:]))
        let body = try await toolFailureBody {
            try await tool.execute(attachmentId: "att3", variant: "thumb", allowedRoots: [FileManager.default.temporaryDirectory.path])
        }

        XCTAssertEqual(body["error"] as? String, "attachment_offloaded")
        let message = body["message"] as? String ?? ""
        XCTAssertTrue(message.contains("iCloud"), message)
        // Nothing started a download, so nothing tells the agent to retry (088 finding #24).
        XCTAssertEqual(body["download_started"] as? Bool, false)
        XCTAssertTrue(message.contains("Do not retry"), message)
        XCTAssertFalse(message.contains("try again"), message)
    }
}

private func makeJPEGDeclaringDimensions(
    pixelWidth: Int,
    pixelHeight: Int,
    declaredWidth: Int,
    declaredHeight: Int,
    name: String
) throws -> URL {
    let url = try makeFixtureImage(name: name, width: pixelWidth, height: pixelHeight)
    let data = try Data(contentsOf: url)
    let bytes = [UInt8](data)
    var i = 0
    while i + 8 < bytes.count {
        guard bytes[i] == 0xFF else {
            i += 1
            continue
        }
        let marker = bytes[i + 1]
        if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
            var patched = [UInt8](data)
            patched[i + 5] = UInt8((declaredHeight >> 8) & 0xFF)
            patched[i + 6] = UInt8(declaredHeight & 0xFF)
            patched[i + 7] = UInt8((declaredWidth >> 8) & 0xFF)
            patched[i + 8] = UInt8(declaredWidth & 0xFF)
            try Data(patched).write(to: url)
            return url
        }
        if marker == 0xD8 || marker == 0xD9 || (0xD0...0xD7).contains(marker) {
            i += 2
            continue
        }
        if i + 3 >= bytes.count { break }
        let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
        i += 2 + length
    }
    throw NSError(domain: "TestImage", code: 4, userInfo: [
        NSLocalizedDescriptionKey: "JPEG SOF marker not found"
    ])
}
