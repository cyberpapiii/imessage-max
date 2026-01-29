// Sources/iMessageMax/Enrichment/VideoProcessor.swift
import Foundation
import AVFoundation
import CoreImage
import CoreGraphics

struct VideoProcessor {
    func getDuration(at path: String) -> Double? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let asset = AVAsset(url: url)
        let duration = asset.duration
        return duration.seconds.isFinite ? duration.seconds : nil
    }

    func getThumbnail(at path: String) -> Data? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)

        let time = CMTime(seconds: 0, preferredTimescale: 1)

        do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            let ciImage = CIImage(cgImage: cgImage)
            let context = CIContext()
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return context.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [:])
        } catch {
            return nil
        }
    }

    struct VideoMetadata {
        let duration: Double
        let width: Int?
        let height: Int?
    }

    func getMetadata(at path: String) -> VideoMetadata? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let asset = AVAsset(url: url)

        guard let duration = getDuration(at: path) else { return nil }

        var width: Int?
        var height: Int?

        if let track = asset.tracks(withMediaType: .video).first {
            let size = track.naturalSize.applying(track.preferredTransform)
            width = Int(abs(size.width))
            height = Int(abs(size.height))
        }

        return VideoMetadata(duration: duration, width: width, height: height)
    }
}
