// Sources/iMessageMax/Models/Attachment.swift
import Foundation

struct AttachmentInfo: Codable {
    let id: String
    let filename: String?
    let mimeType: String?
    let uti: String?
    let totalBytes: Int?
    let chat: String?       // "chat123"
    let from: String?       // Short key
    let ts: String?         // ISO timestamp
}
