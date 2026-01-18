"""get_attachment tool implementation."""

import os
from typing import Optional, Any

from ..db import get_db_connection, DB_PATH
from ..enrichment.images import process_image, FULL_RESOLUTION
from ..enrichment.videos import process_video, FULL_RESOLUTION as VIDEO_FULL_RESOLUTION


def _get_attachment_type(mime_type: Optional[str], uti: Optional[str]) -> str:
    """Determine attachment type from MIME type or UTI."""
    if not mime_type and not uti:
        return "other"

    mime = (mime_type or "").lower()
    uti_str = (uti or "").lower()

    if "image" in mime or "image" in uti_str or "jpeg" in uti_str or "png" in uti_str or "heic" in uti_str:
        return "image"
    elif "video" in mime or "movie" in uti_str or "video" in uti_str:
        return "video"
    elif "audio" in mime or "audio" in uti_str:
        return "audio"
    elif "pdf" in mime or "pdf" in uti_str:
        return "pdf"
    else:
        return "other"


def get_attachment_impl(
    attachment_id: str,
    db_path: str = DB_PATH,
) -> dict[str, Any]:
    """
    Get full-resolution attachment content.

    Use this tool when you need to read text from a screenshot, examine image
    details, or view a photo at full resolution. The get_messages tool returns
    thumbnails (512px) - this tool returns full resolution (1536px).

    Args:
        attachment_id: Attachment identifier (e.g., "att123" or just "123")
        db_path: Path to chat.db (for testing)

    Returns:
        Dict with full-resolution image/video data, or error
    """
    if not attachment_id:
        return {
            "error": "validation_error",
            "message": "attachment_id is required",
        }

    # Extract numeric ID from "attXXX" format
    numeric_id = None
    if attachment_id.startswith("att"):
        try:
            numeric_id = int(attachment_id[3:])
        except ValueError:
            pass
    else:
        try:
            numeric_id = int(attachment_id)
        except ValueError:
            pass

    if numeric_id is None:
        return {
            "error": "validation_error",
            "message": f"Invalid attachment_id format: {attachment_id}",
        }

    try:
        with get_db_connection(db_path) as conn:
            # Look up the attachment
            cursor = conn.execute("""
                SELECT
                    a.ROWID,
                    a.filename,
                    a.mime_type,
                    a.uti,
                    a.total_bytes,
                    a.transfer_name
                FROM attachment a
                WHERE a.ROWID = ?
            """, (numeric_id,))

            row = cursor.fetchone()
            if not row:
                return {
                    "error": "attachment_not_found",
                    "message": f"Attachment not found: {attachment_id}",
                }

            filename = row['filename']
            if not filename:
                return {
                    "error": "attachment_unavailable",
                    "message": "Attachment file path not available",
                }

            # Expand ~ in path
            if filename.startswith('~'):
                filename = os.path.expanduser(filename)

            if not os.path.exists(filename):
                return {
                    "error": "attachment_unavailable",
                    "message": "Attachment file not found on disk",
                }

            att_type = _get_attachment_type(row['mime_type'], row['uti'])
            display_name = row['transfer_name'] or filename.split('/')[-1]

            # Process based on type
            if att_type == 'image':
                result = process_image(filename, max_dimension=FULL_RESOLUTION)
                if result:
                    return {
                        "id": f"att{numeric_id}",
                        "type": "image",
                        "filename": display_name,
                        "size": row['total_bytes'],
                        "resolution": "full",
                        "base64": result['base64'],
                    }
                else:
                    return {
                        "error": "processing_failed",
                        "message": "Failed to process image",
                    }

            elif att_type == 'video':
                result = process_video(filename, max_dimension=VIDEO_FULL_RESOLUTION)
                if result:
                    return {
                        "id": f"att{numeric_id}",
                        "type": "video",
                        "filename": display_name,
                        "size": row['total_bytes'],
                        "resolution": "full",
                        "thumbnail_base64": result['thumbnail_base64'],
                        "duration_seconds": result['duration_seconds'],
                    }
                else:
                    return {
                        "error": "processing_failed",
                        "message": "Failed to process video",
                    }

            else:
                return {
                    "error": "unsupported_type",
                    "message": f"Full resolution not available for type: {att_type}. Only images and videos are supported.",
                    "type": att_type,
                    "filename": display_name,
                    "size": row['total_bytes'],
                }

    except FileNotFoundError:
        return {
            "error": "database_not_found",
            "message": f"Database not found at {db_path}",
        }
    except Exception as e:
        return {
            "error": "internal_error",
            "message": str(e),
        }
