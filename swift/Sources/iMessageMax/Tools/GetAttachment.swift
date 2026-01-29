// Sources/iMessageMax/Tools/GetAttachment.swift
import Foundation
import MCP

/// Result types for get_attachment tool
enum GetAttachmentResult {
    case success(metadata: String, imageData: String, mimeType: String)  // base64 encoded image
    case error(type: String, message: String, details: [String: Any]?)
}

/// Get attachment content at specified resolution variant
struct GetAttachment {
    private let db: Database
    private let imageProcessor: ImageProcessor

    init(db: Database = Database(), imageProcessor: ImageProcessor = ImageProcessor()) {
        self.db = db
        self.imageProcessor = imageProcessor
    }

    // MARK: - Tool Registration

    static func register(on server: Server, db: Database) {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "attachment_id": .object([
                    "type": "string",
                    "description": "Attachment identifier (e.g., \"att123\" or \"123\")",
                ]),
                "variant": .object([
                    "type": "string",
                    "description": "Resolution variant",
                    "enum": ["vision", "thumb", "full"],
                    "default": "vision",
                ]),
            ]),
            "required": ["attachment_id"],
            "additionalProperties": false,
        ])

        server.registerTool(
            name: "get_attachment",
            description: "Get image content by attachment ID. Returns the image at the specified resolution variant: vision (1568px, best for AI analysis), thumb (400px, quick preview), or full (original).",
            inputSchema: inputSchema,
            annotations: Tool.Annotations(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let attachmentId = arguments?["attachment_id"]?.stringValue else {
                let errorResponse = ["error": "validation_error", "message": "attachment_id is required"]
                let jsonData = try JSONSerialization.data(withJSONObject: errorResponse, options: [.sortedKeys])
                return [.text(String(data: jsonData, encoding: .utf8) ?? "{}")]
            }

            let variant = arguments?["variant"]?.stringValue ?? "vision"
            let tool = GetAttachment(db: db)
            let result = tool.execute(attachmentId: attachmentId, variant: variant)

            switch result {
            case .success(let metadata, let imageData, let mimeType):
                // Return metadata as text + image as proper MCP image content
                // This allows Claude to see the image visually without token overhead
                return [
                    .text(metadata),
                    .image(data: imageData, mimeType: mimeType, metadata: nil)
                ]
            case .error(let type, let message, let details):
                var dict: [String: Any] = [
                    "error": type,
                    "message": message
                ]
                if let details = details {
                    for (key, value) in details {
                        dict[key] = value
                    }
                }
                let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
                return [.text(String(data: jsonData, encoding: .utf8) ?? "{}")]
            }
        }
    }

    /// Execute the get_attachment tool
    /// - Parameters:
    ///   - attachmentId: Attachment identifier (e.g., "att123" or just "123")
    ///   - variant: Resolution variant - "vision" (1568px, default), "thumb" (400px), or "full" (original)
    /// - Returns: GetAttachmentResult with image data or error
    func execute(attachmentId: String, variant: String = "vision") -> GetAttachmentResult {
        // Validate variant
        guard let imageVariant = ImageVariant(rawValue: variant) else {
            let validVariants = ImageVariant.allCases.map { $0.rawValue }.sorted()
            return .error(
                type: "validation_error",
                message: "Invalid variant '\(variant)'. Must be one of: \(validVariants.joined(separator: ", "))",
                details: nil
            )
        }

        // Validate attachment_id
        guard !attachmentId.isEmpty else {
            return .error(
                type: "validation_error",
                message: "attachment_id is required",
                details: nil
            )
        }

        // Extract numeric ID from "attXXX" format
        let numericId: Int?
        if attachmentId.hasPrefix("att") {
            numericId = Int(attachmentId.dropFirst(3))
        } else {
            numericId = Int(attachmentId)
        }

        guard let rowId = numericId else {
            return .error(
                type: "validation_error",
                message: "Invalid attachment_id format: \(attachmentId)",
                details: nil
            )
        }

        // Query database for attachment
        do {
            let attachments: [(filename: String?, mimeType: String?, uti: String?, totalBytes: Int64?, transferName: String?)] = try db.query(
                """
                SELECT
                    filename,
                    mime_type,
                    uti,
                    total_bytes,
                    transfer_name
                FROM attachment
                WHERE ROWID = ?
                """,
                params: [rowId]
            ) { row in
                // Column indices: 0=filename, 1=mime_type, 2=uti, 3=total_bytes, 4=transfer_name
                (
                    filename: row.string(0),
                    mimeType: row.string(1),
                    uti: row.string(2),
                    totalBytes: row.optionalInt(3),
                    transferName: row.string(4)
                )
            }

            guard let attachment = attachments.first else {
                return .error(
                    type: "attachment_not_found",
                    message: "Attachment not found: \(attachmentId)",
                    details: nil
                )
            }

            guard let filename = attachment.filename else {
                return .error(
                    type: "attachment_unavailable",
                    message: "Attachment file path not available",
                    details: nil
                )
            }

            // Expand ~ in path
            let expandedPath = (filename as NSString).expandingTildeInPath
            let fileURL = URL(fileURLWithPath: expandedPath)

            // Check if file exists locally
            if !FileManager.default.fileExists(atPath: expandedPath) {
                // Check if it's an iCloud file that can be downloaded
                if let downloaded = tryDownloadFromiCloud(url: fileURL) {
                    if !downloaded {
                        return .error(
                            type: "attachment_offloaded",
                            message: "Attachment is stored in iCloud and download was triggered. Try again in a few seconds.",
                            details: ["path": expandedPath]
                        )
                    }
                } else {
                    return .error(
                        type: "attachment_offloaded",
                        message: "Attachment has been offloaded from this Mac. Open the conversation in Messages.app to download it from iCloud, then try again.",
                        details: nil
                    )
                }
            }

            // Determine attachment type
            let attType = getAttachmentType(mimeType: attachment.mimeType, uti: attachment.uti)
            let displayName = attachment.transferName ?? (expandedPath as NSString).lastPathComponent

            // Process based on type
            switch attType {
            case "image":
                guard let result = imageProcessor.process(at: expandedPath, variant: imageVariant) else {
                    return .error(
                        type: "processing_failed",
                        message: "Failed to process image",
                        details: nil
                    )
                }

                // Build metadata string
                let sizeHuman = formatSize(result.data.count)
                var metadata = "\(displayName) (\(result.width)x\(result.height), \(sizeHuman))"

                // Add warning for full variant if large
                if imageVariant == .full && result.data.count > 200 * 1024 {
                    metadata += " [WARNING: Large file may impact performance]"
                }

                // Encode image data as base64
                let base64Data = result.data.base64EncodedString()

                // ImageProcessor outputs JPEG format
                return .success(metadata: metadata, imageData: base64Data, mimeType: "image/jpeg")

            case "video":
                return .error(
                    type: "unsupported_type",
                    message: "Video attachments are not yet supported with the new variant system. Use list_attachments to see video metadata.",
                    details: [
                        "type": attType,
                        "filename": displayName,
                        "size": attachment.totalBytes as Any
                    ]
                )

            default:
                return .error(
                    type: "unsupported_type",
                    message: "Attachment type '\(attType)' not supported. Only images are supported.",
                    details: [
                        "type": attType,
                        "filename": displayName,
                        "size": attachment.totalBytes as Any
                    ]
                )
            }

        } catch let error as DatabaseError {
            switch error {
            case .notFound(let path):
                return .error(
                    type: "database_not_found",
                    message: "Database not found at \(path)",
                    details: nil
                )
            default:
                return .error(
                    type: "internal_error",
                    message: error.localizedDescription,
                    details: nil
                )
            }
        } catch {
            return .error(
                type: "internal_error",
                message: error.localizedDescription,
                details: nil
            )
        }
    }

    // MARK: - Private Helpers

    /// Determine attachment type from MIME type or UTI
    private func getAttachmentType(mimeType: String?, uti: String?) -> String {
        guard mimeType != nil || uti != nil else {
            return "other"
        }

        let mime = (mimeType ?? "").lowercased()
        let utiStr = (uti ?? "").lowercased()

        if mime.contains("image") || utiStr.contains("image") ||
           utiStr.contains("jpeg") || utiStr.contains("png") || utiStr.contains("heic") {
            return "image"
        } else if mime.contains("video") || utiStr.contains("movie") || utiStr.contains("video") {
            return "video"
        } else if mime.contains("audio") || utiStr.contains("audio") {
            return "audio"
        } else if mime.contains("pdf") || utiStr.contains("pdf") {
            return "pdf"
        } else {
            return "other"
        }
    }

    /// Format bytes as human-readable string
    private func formatSize(_ sizeBytes: Int) -> String {
        if sizeBytes < 1024 {
            return "\(sizeBytes)B"
        } else if sizeBytes < 1024 * 1024 {
            return String(format: "%.1fKB", Double(sizeBytes) / 1024.0)
        } else {
            return String(format: "%.1fMB", Double(sizeBytes) / (1024.0 * 1024.0))
        }
    }

    /// Try to download an iCloud file if it's offloaded
    /// Returns: nil if not an iCloud file, false if download started but not complete, true if available
    private func tryDownloadFromiCloud(url: URL) -> Bool? {
        // Check if this is a ubiquitous (iCloud) item
        do {
            let resourceValues = try url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey
            ])

            guard resourceValues.isUbiquitousItem == true else {
                // Not an iCloud file
                return nil
            }

            // Check download status
            if let status = resourceValues.ubiquitousItemDownloadingStatus {
                if status == .current {
                    // Already downloaded
                    return true
                } else if status == .downloaded {
                    // Downloaded but may need refresh
                    return true
                }
            }

            // Try to start downloading
            try FileManager.default.startDownloadingUbiquitousItem(at: url)

            // Wait briefly for small files
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.5)
                if FileManager.default.fileExists(atPath: url.path) {
                    return true
                }
            }

            // Download started but not complete yet
            return false

        } catch {
            // Not an iCloud file or can't access
            return nil
        }
    }
}
