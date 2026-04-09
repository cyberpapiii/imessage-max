// Sources/iMessageMax/Enrichment/AudioProcessor.swift
import Foundation
import AVFoundation

struct AudioProcessor {
    func getDuration(at path: String) async -> Double? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let asset = AVAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        return duration.seconds.isFinite ? duration.seconds : nil
    }

    struct AudioMetadata {
        let duration: Double
        let codec: String?
    }

    func getMetadata(at path: String) async -> AudioMetadata? {
        guard let duration = await getDuration(at: path) else { return nil }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let asset = AVAsset(url: url)

        var codec: String?
        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            let descriptions = (try? await track.load(.formatDescriptions)) ?? []
            for desc in descriptions {
                let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
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
