import XCTest
import SQLite3
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import iMessageMax

final class GetAttachmentToolTests: XCTestCase {
    func testThumbVariantHonorsMaxDimensionAndDoesNotUpscale() throws {
        let processor = ImageProcessor()

        let largeURL = try makeTestImage(width: 2000, height: 1000, filename: "thumb-large-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: largeURL) }
        let largeResult = try XCTUnwrap(processor.process(at: largeURL.path, variant: .thumb))
        XCTAssertLessThanOrEqual(largeResult.width, 400)
        XCTAssertLessThanOrEqual(largeResult.height, 400)
        XCTAssertEqual(largeResult.width, 400)
        XCTAssertEqual(largeResult.height, 200)

        let smallURL = try makeTestImage(width: 100, height: 50, filename: "thumb-small-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: smallURL) }
        let smallResult = try XCTUnwrap(processor.process(at: smallURL.path, variant: .thumb))
        XCTAssertEqual(smallResult.width, 100, "Images smaller than maxDimension must not be upscaled")
        XCTAssertEqual(smallResult.height, 50, "Images smaller than maxDimension must not be upscaled")
    }

    func testFullVariantOversizeFallsBackToVisionSize() throws {
        // Header-only oversize. process(.full) on a file that *declares*
        // 50MP still hung macos-26 CI: ImageIO's vision thumbnail path
        // allocates from SOF, not from the real 200x100 payload. The
        // production short-circuit is `exceedsFullVariantPixels`; assert
        // that and leave process() to the cheap vision/thumb cases.
        let declaredWidth = 8000
        let declaredHeight = ImageProcessor.maxFullVariantPixels / declaredWidth + 1
        XCTAssertGreaterThan(declaredWidth * declaredHeight, ImageProcessor.maxFullVariantPixels)

        let oversizedURL = try makeJPEGDeclaringDimensions(
            pixelWidth: 200,
            pixelHeight: 100,
            declaredWidth: declaredWidth,
            declaredHeight: declaredHeight,
            filename: "full-oversize-\(UUID().uuidString).jpg"
        )
        defer { try? FileManager.default.removeItem(at: oversizedURL) }

        XCTAssertTrue(
            ImageProcessor.exceedsFullVariantPixels(at: oversizedURL),
            "SOF-declared oversize must trip the pixel cap so process(.full) never decodes"
        )
    }

    func testProcessedOutputIsJPEG() throws {
        let imageURL = try makeTestImage(width: 800, height: 600, filename: "jpeg-format-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let processor = ImageProcessor()
        let result = try XCTUnwrap(processor.process(at: imageURL.path, variant: .vision))
        XCTAssertEqual(result.format, "jpeg")
        XCTAssertGreaterThanOrEqual(result.data.count, 2)
        XCTAssertEqual(Array(result.data.prefix(2)), [0xFF, 0xD8], "Output must start with the JPEG magic bytes")
    }

    func testExecuteReturnsResizedImageForVisionVariant() async throws {
        let imageURL = try makeTestImage(width: 2000, height: 1000, filename: "attachment-large.jpg")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let dbPath = try makeAttachmentTestDatabase(rows: [
            (1, imageURL.path, "image/jpeg", "public.jpeg", 0, "attachment-large.jpg")
        ])
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let tool = GetAttachment(db: Database(path: dbPath))
        let result = await tool.execute(attachmentId: "att1", variant: "vision", allowedRoots: [FileManager.default.temporaryDirectory.path])

        switch result {
        case .success(let metadata, let imageData, let mimeType):
            XCTAssertEqual(mimeType, "image/jpeg")
            XCTAssertEqual(metadata.id, "att1")
            XCTAssertEqual(metadata.type, "image")
            XCTAssertEqual(metadata.name, "attachment-large.jpg")
            XCTAssertTrue(metadata.available)
            XCTAssertFalse(imageData.isEmpty)
        case .error(let type, let message, _):
            XCTFail("Expected image success, got \(type): \(message)")
        }
    }

    func testExecuteReturnsUnsupportedTypeForVideoAttachment() async throws {
        let videoURL = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-video.mp4")
        try Data("video".utf8).write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let dbPath = try makeAttachmentTestDatabase(rows: [
            (2, videoURL.path, "video/mp4", "public.mpeg-4", 5, "attachment-video.mp4")
        ])
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let tool = GetAttachment(db: Database(path: dbPath))
        let result = await tool.execute(attachmentId: "2", variant: "full", allowedRoots: [FileManager.default.temporaryDirectory.path])

        switch result {
        case .success:
            XCTFail("Expected unsupported video error")
        case .error(let type, let message, let details):
            XCTAssertEqual(type, "unsupported_type")
            XCTAssertTrue(message.contains("Video attachments are not yet supported"))
            XCTAssertEqual(details?["type"] as? String, "video")
        }
    }

    func testUnnamedDMChatNameUsesResolvedParticipant() async throws {
        let imageURL = try makeTestImage(
            width: 200,
            height: 100,
            filename: "unnamed-dm-\(UUID().uuidString).jpg"
        )
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
        let result = await tool.execute(
            attachmentId: "att7",
            variant: "thumb",
            allowedRoots: [FileManager.default.temporaryDirectory.path]
        )

        switch result {
        case .success(let metadata, _, _):
            XCTAssertEqual(metadata.chat?.id, "chat22")
            XCTAssertEqual(
                metadata.chat?.name,
                "Sukhmani Kular",
                "Unnamed DM should use the resolved participant name, not chat{rowid}"
            )
        case .error(let type, let message, _):
            XCTFail("Expected image success, got \(type): \(message)")
        }
    }

    func testExecuteReturnsOffloadedErrorWhenImageFileIsMissing() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-missing-attachment.jpg").path

        let dbPath = try makeAttachmentTestDatabase(rows: [
            (3, missingPath, "image/jpeg", "public.jpeg", 12, "missing.jpg")
        ])
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let tool = GetAttachment(db: Database(path: dbPath))
        let result = await tool.execute(attachmentId: "att3", variant: "thumb", allowedRoots: [FileManager.default.temporaryDirectory.path])

        switch result {
        case .success:
            XCTFail("Expected offloaded attachment error")
        case .error(let type, let message, _):
            XCTAssertEqual(type, "attachment_offloaded")
            XCTAssertTrue(message.contains("offloaded") || message.contains("iCloud"))
        }
    }
}

private func makeAttachmentTestDatabase(
    rows: [(id: Int, filename: String, mimeType: String?, uti: String?, totalBytes: Int64, transferName: String?)]
) throws -> String {
    let dbURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("imessage-max-attachment-\(UUID().uuidString).sqlite")

    var db: OpaquePointer?
    guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
        XCTFail("Failed to open attachment sqlite database")
        return dbURL.path
    }
    defer { sqlite3_close(db) }

    let createStatement = """
        CREATE TABLE attachment (
            ROWID INTEGER PRIMARY KEY,
            filename TEXT,
            mime_type TEXT,
            uti TEXT,
            total_bytes INTEGER,
            transfer_name TEXT
        );
        """
    guard sqlite3_exec(db, createStatement, nil, nil, nil) == SQLITE_OK else {
        XCTFail("Failed to create attachment table")
        return dbURL.path
    }

    for row in rows {
        let transferNameSQL = row.transferName.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
        let mimeSQL = row.mimeType.map { "'\($0)'" } ?? "NULL"
        let utiSQL = row.uti.map { "'\($0)'" } ?? "NULL"
        let insert = """
            INSERT INTO attachment (ROWID, filename, mime_type, uti, total_bytes, transfer_name)
            VALUES (\(row.id), '\(row.filename.replacingOccurrences(of: "'", with: "''"))', \(mimeSQL), \(utiSQL), \(row.totalBytes), \(transferNameSQL));
            """
        guard sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            XCTFail("Failed to insert attachment row: \(message)")
            break
        }
    }

    return dbURL.path
}

private func makeTestImage(width: Int, height: Int, filename: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw NSError(domain: "TestImage", code: 1)
    }

    context.setFillColor(CGColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw NSError(domain: "TestImage", code: 2)
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "TestImage", code: 3)
    }

    return url
}

/// Tiny JPEG whose SOF width/height are patched so ImageIO reports an
/// oversize pixel count without encoding that many pixels.
private func makeJPEGDeclaringDimensions(
    pixelWidth: Int,
    pixelHeight: Int,
    declaredWidth: Int,
    declaredHeight: Int,
    filename: String
) throws -> URL {
    let url = try makeTestImage(width: pixelWidth, height: pixelHeight, filename: filename)
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
