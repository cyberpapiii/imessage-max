import AVFoundation
import CoreGraphics
import Foundation
import MCP

/// Still frames from a video attachment, spread across its length.
enum VideoFrames {
    static let count = 4

    /// Each frame is half the variant's size on its long side, so the frames
    /// together hold about as many pixels as one image of that variant. Full
    /// frames stop at 1568px: four originals could be tens of megabytes.
    static func frameDimension(_ variant: ImageVariant) -> Int {
        guard let maxDimension = variant.maxDimension else { return 1568 }
        return maxDimension / 2
    }

    struct Detail: Encodable, Sendable {
        let durationS: Double
        let frameTimesS: [Double]

        private enum CodingKeys: String, CodingKey {
            case durationS = "duration_s"
            case frameTimesS = "frame_times_s"
        }
    }

    struct Frame {
        let seconds: Double
        let image: CGImage
    }

    /// The middle of each of `count` equal spans, so no frame is the black
    /// first frame or the last one.
    static func sampleTimes(duration: Double, count: Int) -> [Double] {
        guard duration > 0 else { return [0] }
        let n = max(1, min(count, Int(duration.rounded(.up))))
        return (0..<n).map { duration * (Double($0) * 2 + 1) / Double(n * 2) }
    }

    static func extract(path: String, maxDimension: Int) async throws -> (duration: Double, frames: [Frame]) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration: Double
        do {
            guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
                throw ToolFailure("processing_failed", "The video has no picture track")
            }
            duration = try await asset.load(.duration).seconds
        } catch let failure as ToolFailure {
            throw failure
        } catch {
            throw ToolFailure("processing_failed", "The video could not be opened")
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var frames: [Frame] = []
        for seconds in sampleTimes(duration: duration.isFinite ? duration : 0, count: count) {
            guard let (image, actual) = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { continue }
            frames.append(Frame(seconds: actual.seconds, image: image))
        }
        guard !frames.isEmpty else {
            throw ToolFailure("processing_failed", "No frames could be read from the video")
        }
        return (duration, frames)
    }

    /// get_attachment's reply for a video: its frames as images, with the
    /// duration and each frame's time in the metadata.
    static func content(of file: AttachmentFile, variant: ImageVariant, processor: ImageProcessor) async throws -> TypedAttachmentContent {
        let (duration, frames) = try await extract(path: file.path, maxDimension: frameDimension(variant))
        let encoded = frames.compactMap { frame in processor.jpeg(frame.image).map { (seconds: frame.seconds, image: $0) } }
        let detail = Detail(durationS: tenths(duration), frameTimesS: encoded.map { tenths($0.seconds) })
        let blocks = encoded.map {
            Tool.Content.plainImage(data: $0.image.data.base64EncodedString(), mimeType: "image/\($0.image.format)")
        }
        return TypedAttachmentContent(detail: detail, blocks: blocks)
    }

    private static func tenths(_ seconds: Double) -> Double {
        (seconds * 10).rounded() / 10
    }
}
