// Sources/iMessageMax/Models/AttachmentType.swift
import Foundation

/// Attachment type derived from MIME type or UTI
enum AttachmentType: String, Codable {
    case image
    case video
    case audio
    case pdf
    case document
    case other

    static func from(mimeType: String?, uti: String?) -> AttachmentType {
        let mime = (mimeType ?? "").lowercased()
        let utiStr = (uti ?? "").lowercased()

        if mime.contains("image") || utiStr.contains("image") ||
            utiStr.contains("jpeg") || utiStr.contains("png") || utiStr.contains("heic") {
            return .image
        } else if mime.contains("video") || utiStr.contains("movie") || utiStr.contains("video") {
            return .video
        } else if mime.contains("audio") || utiStr.contains("audio") {
            return .audio
        } else if mime.contains("pdf") || utiStr.contains("pdf") {
            return .pdf
        } else if mime.contains("document") || mime.contains("msword") ||
            mime.contains("spreadsheet") || mime.contains("presentation") {
            return .document
        } else {
            return .other
        }
    }
}
