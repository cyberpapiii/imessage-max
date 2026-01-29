// Sources/iMessageMax/Enrichment/AudioProcessor.swift
import Foundation
import AVFoundation

struct AudioProcessor {
    func getDuration(at path: String) -> Double? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let asset = AVAsset(url: url)
        let duration = asset.duration
        return duration.seconds.isFinite ? duration.seconds : nil
    }

    struct AudioMetadata {
        let duration: Double
        let codec: String?
    }

    func getMetadata(at path: String) -> AudioMetadata? {
        guard let duration = getDuration(at: path) else { return nil }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let asset = AVAsset(url: url)

        var codec: String?
        if let track = asset.tracks(withMediaType: .audio).first {
            for desc in track.formatDescriptions {
                let formatDesc = desc as! CMFormatDescription
                let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)
                codec = String(format: "%c%c%c%c",
                              (mediaSubType >> 24) & 0xFF,
                              (mediaSubType >> 16) & 0xFF,
                              (mediaSubType >> 8) & 0xFF,
                              mediaSubType & 0xFF)
                break
            }
        }

        return AudioMetadata(duration: duration, codec: codec)
    }
}
