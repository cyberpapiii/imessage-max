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
        // Hit the pixel-count short-circuit, not the 8MB re-encode check.
        // A 6000x4000 noise JPEG (under the 50M-pixel cap) made CI
        // `--parallel` stall for minutes: Core Image on the macos-26 runner
        // has no GPU and encodes that bitmap on CPU. A solid image just
        // over `maxFullVariantPixels` is a tiny JPEG and never enters that
        // path. Same fallback, cheap enough for a runner.
        let width = 8000
        let height = ImageProcessor.maxFullVariantPixels / width + 1
        XCTAssertGreaterThan(width * height, ImageProcessor.maxFullVariantPixels)

        let oversizedURL = try makeTestImage(
            width: width,
            height: height,
            filename: "full-oversize-\(UUID().uuidString).jpg"
        )
        defer { try? FileManager.default.removeItem(at: oversizedURL) }

        let processor = ImageProcessor()
        let result = try XCTUnwrap(processor.process(at: oversizedURL.path, variant: .full))

        // Falling back to .vision means neither dimension can exceed its 1568px cap.
        XCTAssertLessThanOrEqual(result.width, 1568, "Oversized full variant should fall back to vision-sized dimensions")
        XCTAssertLessThanOrEqual(result.height, 1568, "Oversized full variant should fall back to vision-sized dimensions")
        XCTAssertLessThanOrEqual(result.data.count, 8 * 1024 * 1024, "Fallback output should be well under the full-variant cap")
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
