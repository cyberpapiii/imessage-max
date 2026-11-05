import Foundation

/// Attachment type derived from MIME type or UTI
enum AttachmentType: String, Codable {
    case image
    case video
    case audio
    case pdf
    case document
    case other

    /// Substrings of the lowercased MIME type or UTI that mark each kind,
    /// in the order `from` tries them. Both `from` and `sqlPredicate` read
    /// this one table.
    private static let markers: [(type: AttachmentType, mime: [String], uti: [String])] = [
        (.image, ["image"], ["image", "jpeg", "png", "heic"]),
        (.video, ["video"], ["movie", "video"]),
        (.audio, ["audio"], ["audio"]),
        (.pdf, ["pdf"], ["pdf"]),
        (.document, ["document", "msword", "spreadsheet", "presentation"], []),
    ]

    static func from(mimeType: String?, uti: String?) -> AttachmentType {
        let mime = (mimeType ?? "").lowercased()
        let utiStr = (uti ?? "").lowercased()
        return markers.first { marker in
            marker.mime.contains { mime.contains($0) } || marker.uti.contains { utiStr.contains($0) }
        }?.type ?? .other
    }

    /// SQL boolean expression over `alias.mime_type` / `alias.uti`: the
    /// row carries this kind's markers. Unlike `from`, it does not check
    /// that no earlier kind matched first. Returns nil for `"any"` and
    /// unknown filters.
    static func sqlPredicate(for typeFilter: String?, alias: String = "a") -> String? {
        guard let marker = markers.first(where: { $0.type.rawValue == typeFilter }) else { return nil }

        let mime = "LOWER(COALESCE(\(alias).mime_type, ''))"
        let uti = "LOWER(COALESCE(\(alias).uti, ''))"
        return (marker.mime.map { "\(mime) LIKE '%\($0)%'" } + marker.uti.map { "\(uti) LIKE '%\($0)%'" })
            .joined(separator: " OR ")
    }
}
