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

    /// SQL boolean expression over `alias.mime_type` / `alias.uti`.
    /// Returns nil for `"any"` / unknown filters.
    static func sqlPredicate(for typeFilter: String?, alias: String = "a") -> String? {
        guard let typeFilter, typeFilter != "any" else { return nil }

        let mime = "LOWER(COALESCE(\(alias).mime_type, ''))"
        let uti = "LOWER(COALESCE(\(alias).uti, ''))"
        switch typeFilter {
        case "image":
            return "\(mime) LIKE '%image%' OR \(uti) LIKE '%image%' OR \(uti) LIKE '%jpeg%' OR \(uti) LIKE '%png%' OR \(uti) LIKE '%heic%'"
        case "video":
            return "\(mime) LIKE '%video%' OR \(uti) LIKE '%movie%' OR \(uti) LIKE '%video%'"
        case "audio":
            return "\(mime) LIKE '%audio%' OR \(uti) LIKE '%audio%'"
        case "pdf":
            return "\(mime) LIKE '%pdf%' OR \(uti) LIKE '%pdf%'"
        case "document":
            return "\(mime) LIKE '%document%' OR \(mime) LIKE '%msword%' OR \(mime) LIKE '%spreadsheet%' OR \(mime) LIKE '%presentation%'"
        default:
            return nil
        }
    }
}
