import AVFoundation
import CoreGraphics
import ImageIO
import XCTest
@testable import iMessageMax

final class VideoAttachmentTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func fetch(_ url: URL, variant: String) async throws -> AttachmentReply {
        let fixture = try ToolTestDatabase(name: "video")
        try fixture.insertAttachment(rowId: 9, filename: url.path, mimeType: "video/quicktime", uti: "com.apple.quicktime-movie", transferName: "clip.mov")
        let tool = GetAttachment(db: fixture.database(), resolver: ContactResolver(seedCache: [:]))
        return try attachmentReply(try await tool.execute(
            attachmentId: "att9", variant: variant,
            allowedRoots: [FileManager.default.temporaryDirectory.path]
        ))
    }

    func testVideoReturnsFramesSpreadAcrossItsLength() async throws {
        let colors: [(r: UInt8, g: UInt8, b: UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
        let url = try makeVideo(width: 1280, height: 720, secondsPerColor: 2, colors: colors)
        files.append(url)

        let reply = try await fetch(url, variant: "vision")

        XCTAssertEqual(reply.metadata["type"] as? String, "video")
        XCTAssertEqual(try XCTUnwrap(reply.metadata["duration_s"] as? Double), 8, accuracy: 0.1)
        let times = try XCTUnwrap(reply.metadata["frame_times_s"] as? [Double])
        XCTAssertEqual(times.count, VideoFrames.count)
        for (time, expected) in zip(times, [1.0, 3.0, 5.0, 7.0]) {
            XCTAssertEqual(time, expected, accuracy: 0.3)
        }
        XCTAssertTrue(reply.texts.isEmpty)
        XCTAssertEqual(reply.images.count, VideoFrames.count)
        for (image, color) in zip(reply.images, colors) {
            XCTAssertEqual(image.mimeType, "image/jpeg")
            let frame = try decode(image.data)
            XCTAssertEqual(frame.width, 784, "vision frames are half of 1568 on the long side")
            XCTAssertEqual(frame.height, 441)
            let center = try centerPixel(frame)
            XCTAssertEqual(Int(center.r), Int(color.r), accuracy: 40, "frame shows the color on screen at its time")
            XCTAssertEqual(Int(center.g), Int(color.g), accuracy: 40)
            XCTAssertEqual(Int(center.b), Int(color.b), accuracy: 40)
        }
    }

    func testThumbFramesAreSmallAndAShortClipGetsFewerFrames() async throws {
        let url = try makeVideo(width: 1280, height: 720, secondsPerColor: 1, colors: [(10, 200, 10), (200, 10, 10)], rotated: true)
        files.append(url)

        let reply = try await fetch(url, variant: "thumb")

        XCTAssertEqual(reply.images.count, 2, "a 2 second clip gets one frame per second, not four near-duplicates")
        let frame = try decode(try XCTUnwrap(reply.images.first).data)
        XCTAssertEqual(frame.height, 200, "a phone-portrait video, stored landscape and rotated, gives frames 200px tall")
        XCTAssertEqual(frame.width, 113, accuracy: 1)
    }

    func testUnreadableVideoIsAProcessingFailure() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-broken.mov")
        try Data("not a movie".utf8).write(to: url)
        files.append(url)

        let body = try await toolFailureBody { try await self.fetch(url, variant: "vision") }
        XCTAssertEqual(body["error"] as? String, "processing_failed")
    }
}

private func decode(_ data: Data) throws -> CGImage {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

private func centerPixel(_ image: CGImage) throws -> (r: UInt8, g: UInt8, b: UInt8) {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try XCTUnwrap(CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
    return (pixel[0], pixel[1], pixel[2])
}

/// An H.264 movie that shows each color, full frame, for `secondsPerColor`.
/// `rotated` stores it the way a phone stores a portrait video: landscape
/// pixels with a 90 degree display transform.
private func makeVideo(width: Int, height: Int, secondsPerColor: Int, colors: [(r: UInt8, g: UInt8, b: UInt8)], rotated: Bool = false) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-clip.mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    let fps = 2
    for (index, color) in colors.enumerated() {
        for tick in 0..<(fps * secondsPerColor) {
            while !input.isReadyForMoreMediaData { usleep(1_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height {
                for x in 0..<width {
                    let p = base + y * rowBytes + x * 4
                    p[0] = color.b; p[1] = color.g; p[2] = color.r; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let frame = index * fps * secondsPerColor + tick
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))))
        }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(colors.count * fps * secondsPerColor), timescale: CMTimeScale(fps)))
    writer.finishWriting { done.signal() }
    done.wait()
    XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    return url
}
