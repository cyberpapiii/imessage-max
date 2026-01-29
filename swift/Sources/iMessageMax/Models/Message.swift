// Sources/iMessageMax/Models/Message.swift
import Foundation

struct Message: Codable {
    let id: String          // "msg123"
    let guid: String
    let text: String?
    let ts: String          // ISO timestamp
    let from: String        // Short key into people map
    let fromMe: Bool
    let reactions: [String]?    // ["❤️ nick", "😂 andrew"]
    let media: [MediaMetadata]?
    let replyTo: String?
    let edited: Bool?
    let session: String?    // Session grouping
}

struct MediaMetadata: Codable {
    let id: String          // "att123"
    let type: String        // "image", "video", "audio", "file"
    let filename: String?
    let sizeBytes: Int?
    let dimensions: Dimensions?
    let duration: Double?   // For audio/video

    struct Dimensions: Codable {
        let width: Int
        let height: Int
    }
}
