// Sources/iMessageMax/Tools/GetAttachment.swift
import Foundation
import MCP

enum GetAttachmentResult {
    case success(metadata: AttachmentMetadataSummary, imageData: String, mimeType: String)
    case error(type: String, message: String, details: [String: Any]?)
}

struct AttachmentMetadataSummary: Codable {
    let id: String
    let type: String
    let name: String
    let chat: ChatReference?
    let available: Bool
}

struct GetAttachment {
    private let db: Database
    private let imageProcessor: ImageProcessor
    private let resolver: ContactResolver

    init(
        db: Database = Database(),
        imageProcessor: ImageProcessor = ImageProcessor(),
        resolver: ContactResolver = ContactResolver()
    ) {
        self.db = db
        self.imageProcessor = imageProcessor
        self.resolver = resolver
    }

    // MARK: - Tool Registration

    static func register(on server: Server, db: Database, resolver: ContactResolver) {
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
                title: "Get Attachment",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let attachmentId = arguments?["attachment_id"]?.stringValue else {
                let errorResponse = ["error": "validation_error", "message": "attachment_id is required"]
                throw ToolError(content: [.plainText(try FormatUtils.encodeJSONObject(errorResponse))])
            }

            let variant = arguments?["variant"]?.stringValue ?? "vision"
            let tool = GetAttachment(db: db, resolver: resolver)
            let result = await tool.execute(attachmentId: attachmentId, variant: variant)

            switch result {
            case .success(let metadata, let imageData, let mimeType):
                return [
                    .plainText(try FormatUtils.encodeJSON(metadata)),
                    .plainImage(data: imageData, mimeType: mimeType)
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
                throw ToolError(content: [.plainText(try FormatUtils.encodeJSONObject(dict))])
            }
        }
    }

    /// - Parameter allowedRoots: File-system roots that attachment paths must reside under.
    ///   Defaults to `AttachmentPathPolicy.defaultRoots`. Inject a different value in tests.
    func execute(attachmentId: String, variant: String = "vision", allowedRoots: [String] = AttachmentPathPolicy.defaultRoots) async -> GetAttachmentResult {
        guard let imageVariant = ImageVariant(rawValue: variant) else {
            let validVariants = ImageVariant.allCases.map { $0.rawValue }.sorted()
            return .error(
                type: "validation_error",
                message: "Invalid variant '\(variant)'. Must be one of: \(validVariants.joined(separator: ", "))",
                details: nil
            )
        }

        guard !attachmentId.isEmpty else {
            return .error(
                type: "validation_error",
                message: "attachment_id is required",
                details: nil
            )
        }

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

            // Contain paths to allowed roots (security)
            guard let expandedPath = AttachmentPathPolicy.validatedPath(filename, allowedRoots: allowedRoots) else {
                return .error(
                    type: "attachment_path_invalid",
                    message: "Attachment path is outside the Messages attachment store",
                    details: nil
                )
            }
            let fileURL = URL(fileURLWithPath: expandedPath)

            if !FileManager.default.fileExists(atPath: expandedPath) {
                // iCloud offload: trigger download and ask caller to retry
                if let downloaded = await tryDownloadFromiCloud(url: fileURL) {
                    if !downloaded {
                        return .error(
                            type: "attachment_offloaded",
                            message: "Attachment is stored in iCloud and download was triggered. Try again in a few seconds.",
                            details: ["filename": fileURL.lastPathComponent]
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

            let attachmentType = AttachmentType.from(
                mimeType: attachment.mimeType,
                uti: attachment.uti
            )
            let attType = attachmentType.rawValue
            let displayName = attachment.transferName ?? (expandedPath as NSString).lastPathComponent
            let chat = try await resolveAttachmentChat(rowId: rowId)

            switch attachmentType {
            case .image:
                guard let result = imageProcessor.process(at: expandedPath, variant: imageVariant) else {
                    return .error(
                        type: "processing_failed",
                        message: "Failed to process image",
                        details: nil
                    )
                }

                let base64Data = result.data.base64EncodedString()

                return .success(
                    metadata: AttachmentMetadataSummary(
                        id: "att\(rowId)",
                        type: attType,
                        name: displayName,
                        chat: chat,
                        available: true
                    ),
                    imageData: base64Data,
                    mimeType: "image/jpeg"
                )

            case .video:
                return .error(
                    type: "unsupported_type",
                    message: "Video attachments are not yet supported with the new variant system. Use list_attachments to see video metadata.",
                    details: [
                        "type": attType,
                        "filename": displayName,
                        "size": attachment.totalBytes as Any
                    ]
                )

            case .audio, .pdf, .document, .other:
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
            let mapped = ToolErrorMapping.map(error, context: "get_attachment")
            return .error(
                type: mapped.code,
                message: mapped.message,
                details: nil
            )
        } catch {
            return .error(
                type: "internal_error",
                message: ClientErrorMessages.internalDetail(error, context: "get_attachment"),
                details: nil
            )
        }
    }

    // MARK: - Private Helpers

    private func resolveAttachmentChat(rowId: Int) async throws -> ChatReference? {
        let rows: [(Int64, String?)]
        do {
            rows = try db.query(
                """
                SELECT c.ROWID, c.display_name
                FROM attachment a
                JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
                JOIN chat_message_join cmj ON maj.message_id = cmj.message_id
                JOIN chat c ON cmj.chat_id = c.ROWID
                WHERE a.ROWID = ?
                LIMIT 1
                """,
                params: [rowId]
            ) { row in
                (row.int(0), row.string(1))
            }
        } catch {
            return nil
        }

        guard let row = rows.first else { return nil }
        let displayName = row.1?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let displayName, !displayName.isEmpty {
            name = displayName
        } else {
            let participants = try await ChatSummaryQueries.participants(
                db: db,
                chatId: row.0,
                resolver: resolver
            )
            let identity = ChatIdentity(
                mcpId: "chat\(row.0)",
                guid: nil,
                explicitName: nil,
                participants: participants.map {
                    ChatIdentity.makeParticipant(handle: $0.handle, contactName: $0.name)
                }
            )
            name = identity.displayName
        }
        return ChatReference(
            id: "chat\(row.0)",
            name: name
        )
    }

    /// iCloud offload: nil = not ubiquitous, false = download started (retry), true = available.
    private func tryDownloadFromiCloud(url: URL) async -> Bool? {
        do {
            let resourceValues = try url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey
            ])

            guard resourceValues.isUbiquitousItem == true else {
                return nil
            }

            if let status = resourceValues.ubiquitousItemDownloadingStatus {
                if status == .current {
                    return true
                } else if status == .downloaded {
                    return true
                }
            }

            try FileManager.default.startDownloadingUbiquitousItem(at: url)

            for _ in 0..<10 {
                await AsyncTimeout.sleep(.milliseconds(500))
                if FileManager.default.fileExists(atPath: url.path) {
                    return true
                }
            }

            return false

        } catch {
            return nil
        }
    }
}
