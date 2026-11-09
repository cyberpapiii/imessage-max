import Foundation
import MCP

/// What get_attachment returns: one JSON metadata block, then the blocks that
/// carry the attachment itself (images, or text).
struct AttachmentContent {
    let metadata: AttachmentMetadataSummary
    let blocks: [Tool.Content]

    func toolContent() throws -> [Tool.Content] {
        [.plainText(try FormatUtils.encodeJSON(metadata))] + blocks
    }
}

/// The blocks for one attachment type, plus the fields that type adds to the
/// metadata block.
struct TypedAttachmentContent {
    var detail: (any Encodable & Sendable)?
    var blocks: [Tool.Content]
}

/// A file get_attachment has found on disk and may read.
struct AttachmentFile {
    let rowId: Int
    let path: String
    let type: AttachmentType
    let uti: String?
    let mimeType: String?
    let totalBytes: Int64?
    let displayName: String
}

private struct AttachmentFailure: Encodable, Sendable {
    let error: String
    let message: String
    var type: String?
    var filename: String?
    var size: Int64?
    var downloadStarted: Bool?

    private enum CodingKeys: String, CodingKey {
        case error, message, type, filename, size
        case downloadStarted = "download_started"
    }
}

struct AttachmentMetadataSummary: Encodable {
    let id: String
    let type: String
    let name: String
    let chat: ChatReference?
    let available: Bool
    /// Type-specific fields, encoded at the top level beside the ones above.
    var detail: (any Encodable & Sendable)?

    private enum CodingKeys: String, CodingKey {
        case id, type, name, chat, available
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(chat, forKey: .chat)
        try container.encode(available, forKey: .available)
        try detail?.encode(to: encoder)
    }
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
            description: "Get an attachment's content by attachment ID. The first block is JSON metadata. An image comes back at the requested resolution variant: vision (1568px, best for AI analysis), thumb (400px, quick preview), or full (original size). A video comes back as up to \(VideoFrames.count) still frames spread across its length, each half the variant's size on its long side (full: 1568px), with duration_s and frame_times_s in the metadata.",
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
            return try await tool.execute(attachmentId: attachmentId, variant: variant).toolContent()
        }
    }

    /// iMessage Max cannot make Messages download a file it keeps only in
    /// iCloud, so this reply must not invite a retry.
    static let offloadedMessage =
        "The attachment is stored only in iCloud, and iMessage Max cannot download it. Do not retry. "
        + "It becomes available after someone opens the conversation in Messages on this Mac and "
        + "Messages downloads it."

    func execute(attachmentId: String, variant: String = "vision", allowedRoots: [String] = AttachmentPathPolicy.defaultRoots) async throws -> AttachmentContent {
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

        guard let expandedPath = AttachmentPathPolicy.validatedPath(filename, allowedRoots: allowedRoots) else {
            throw ToolFailure("attachment_path_invalid", "Attachment path is outside the Messages attachment store")
        }
        let fileURL = URL(fileURLWithPath: expandedPath)

        if !FileManager.default.fileExists(atPath: expandedPath) {
            if let downloaded = await tryDownloadFromiCloud(url: fileURL) {
                if !downloaded {
                    throw ToolFailure(code: "attachment_offloaded", body: AttachmentFailure(error: "attachment_offloaded", message: "The attachment is stored in iCloud, and a download has started. Try again in a few seconds.", filename: fileURL.lastPathComponent, downloadStarted: true))
                }
            } else {
                throw ToolFailure(code: "attachment_offloaded", body: AttachmentFailure(error: "attachment_offloaded", message: Self.offloadedMessage, filename: fileURL.lastPathComponent, downloadStarted: false))
            }
        }

        let attachmentType = AttachmentType.from(
            mimeType: attachment.mimeType,
            uti: attachment.uti
        )
        let file = AttachmentFile(
            rowId: rowId,
            path: expandedPath,
            type: attachmentType,
            uti: attachment.uti,
            mimeType: attachment.mimeType,
            totalBytes: attachment.totalBytes,
            displayName: attachment.transferName ?? (expandedPath as NSString).lastPathComponent
        )
        let typed = try await content(of: file, variant: imageVariant)
        let chat = try await resolveAttachmentChat(rowId: rowId)

        return AttachmentContent(
            metadata: AttachmentMetadataSummary(
                id: AttachmentIdentifier.format(rowId),
                type: attachmentType.rawValue,
                name: file.displayName,
                chat: chat,
                available: true,
                detail: typed.detail
            ),
            blocks: typed.blocks
        )
    }

    private func content(of file: AttachmentFile, variant: ImageVariant) async throws -> TypedAttachmentContent {
        switch file.type {
        case .image:
            return TypedAttachmentContent(blocks: [try imageBlock(file, variant: variant)])

        case .video:
            return try await VideoFrames.content(of: file, variant: variant, processor: imageProcessor)

        case .audio:
            throw Self.unsupported(file, "Attachment type 'audio' is not supported. Only images are supported.")

        case .pdf, .document, .other:
            throw Self.unsupported(file, "Attachment type '\(file.type.rawValue)' is not supported. Only images are supported.")
        }
    }

    private func imageBlock(_ file: AttachmentFile, variant: ImageVariant) throws -> Tool.Content {
        guard let result = imageProcessor.process(at: file.path, variant: variant) else {
            throw ToolFailure("processing_failed", "Failed to process image")
        }
        return .plainImage(data: result.data.base64EncodedString(), mimeType: "image/\(result.format)")
    }

    static func unsupported(_ file: AttachmentFile, _ message: String) -> ToolFailure {
        ToolFailure(code: "unsupported_type", body: AttachmentFailure(error: "unsupported_type", message: message, type: file.type.rawValue, filename: file.displayName, size: file.totalBytes))
    }

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
                  AND c.ROWID = \(ChatScope.byMessage.listedChat(of: "maj.message_id"))
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
        return try await ChatReferences(
            [ChatPage.Chat(id: row.0, explicitName: row.1)],
            db: db,
            resolver: resolver
        )[row.0]
    }

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
