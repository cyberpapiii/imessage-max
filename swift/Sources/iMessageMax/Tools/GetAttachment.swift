// Sources/iMessageMax/Tools/GetAttachment.swift
import Foundation
import MCP

struct AttachmentImage {
    let metadata: AttachmentMetadataSummary
    let imageData: String
    let mimeType: String
}

private struct AttachmentFailure: Encodable, Sendable {
    let error: String
    let message: String
    var type: String?
    var filename: String?
    var size: Int64?
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
        db: Database,
        imageProcessor: ImageProcessor = ImageProcessor(),
        resolver: ContactResolver
    ) {
        self.db = db
        self.imageProcessor = imageProcessor
        self.resolver = resolver
    }

    // MARK: - Tool Registration

    static func definition(db: Database, resolver: ContactResolver) -> ToolDefinition {
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

        return ToolDefinition(
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
                throw ToolFailure("validation_error", "attachment_id is required")
            }

            let variant = arguments?["variant"]?.stringValue ?? "vision"
            let tool = GetAttachment(db: db, resolver: resolver)
            let image = try await tool.execute(attachmentId: attachmentId, variant: variant)
            return [
                .plainText(try FormatUtils.encodeJSON(image.metadata)),
                .plainImage(data: image.imageData, mimeType: image.mimeType),
            ]
        }
    }

    /// - Parameter allowedRoots: File-system roots that attachment paths must reside under.
    ///   Defaults to `AttachmentPathPolicy.defaultRoots`. Inject a different value in tests.
    func execute(attachmentId: String, variant: String = "vision", allowedRoots: [String] = AttachmentPathPolicy.defaultRoots) async throws -> AttachmentImage {
        guard let imageVariant = ImageVariant(rawValue: variant) else {
            let validVariants = ImageVariant.allCases.map { $0.rawValue }.sorted()
            throw ToolFailure("validation_error", "Invalid variant '\(variant)'. Must be one of: \(validVariants.joined(separator: ", "))")
        }

        guard !attachmentId.isEmpty else {
            throw ToolFailure("validation_error", "attachment_id is required")
        }

        guard let rowId = AttachmentIdentifier.parse(attachmentId) else {
            throw ToolFailure("validation_error", "Invalid attachment_id format: \(attachmentId)")
        }

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
            throw ToolFailure("attachment_not_found", ClientErrorMessages.attachmentNotFound(attachmentId))
        }

        guard let filename = attachment.filename else {
            throw ToolFailure("attachment_unavailable", "Attachment file path not available")
        }

        // Contain paths to allowed roots (security)
        guard let expandedPath = AttachmentPathPolicy.validatedPath(filename, allowedRoots: allowedRoots) else {
            throw ToolFailure("attachment_path_invalid", "Attachment path is outside the Messages attachment store")
        }
        let fileURL = URL(fileURLWithPath: expandedPath)

        if !FileManager.default.fileExists(atPath: expandedPath) {
            // iCloud offload: trigger download and ask caller to retry
            if let downloaded = await tryDownloadFromiCloud(url: fileURL) {
                if !downloaded {
                    throw ToolFailure(code: "attachment_offloaded", body: AttachmentFailure(error: "attachment_offloaded", message: "Attachment is stored in iCloud and download was triggered. Try again in a few seconds.", filename: fileURL.lastPathComponent))
                }
            } else {
                throw ToolFailure("attachment_offloaded", "Attachment has been offloaded from this Mac. Open the conversation in Messages.app to download it from iCloud, then try again.")
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
                throw ToolFailure("processing_failed", "Failed to process image")
            }

            let base64Data = result.data.base64EncodedString()

            return AttachmentImage(
                metadata: AttachmentMetadataSummary(
                    id: AttachmentIdentifier.format(rowId),
                    type: attType,
                    name: displayName,
                    chat: chat,
                    available: true
                ),
                imageData: base64Data,
                mimeType: "image/jpeg"
            )

        case .video:
            throw ToolFailure(code: "unsupported_type", body: AttachmentFailure(error: "unsupported_type", message: "Video attachments are not yet supported with the new variant system. Use list_attachments to see video metadata.", type: attType, filename: displayName, size: attachment.totalBytes))

        case .audio, .pdf, .document, .other:
            throw ToolFailure(code: "unsupported_type", body: AttachmentFailure(error: "unsupported_type", message: "Attachment type '\(attType)' not supported. Only images are supported.", type: attType, filename: displayName, size: attachment.totalBytes))
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
                mcpId: ChatIdentifier.format(row.0),
                guid: nil,
                explicitName: nil,
                participants: participants.map {
                    ChatIdentity.makeParticipant(handle: $0.handle, contactName: $0.name)
                }
            )
            name = identity.displayName
        }
        return ChatReference(
            id: ChatIdentifier.format(row.0),
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
