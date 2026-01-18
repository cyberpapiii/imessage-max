"""get_attachment tool implementation."""

import base64
import os
from io import BytesIO
from pathlib import Path
from typing import Any, Literal, Optional

from fastmcp.utilities.types import Image as MCPImage

# Register HEIF opener with Pillow
import pillow_heif
pillow_heif.register_heif_opener()

from PIL import Image

from ..db import get_db_connection, DB_PATH


# Variant specifications
VALID_VARIANTS = {"vision", "thumb", "full"}
VARIANT_SPECS = {
    "vision": {"max_dimension": 1568, "quality": 80},
    "thumb": {"max_dimension": 400, "quality": 75},
    "full": {"max_dimension": None, "quality": None},
}


def _format_size(size_bytes: int) -> str:
    """Format bytes as human-readable string."""
    if size_bytes < 1024:
        return f"{size_bytes}B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f}KB"
    else:
        return f"{size_bytes / (1024 * 1024):.1f}MB"


def process_image_for_variant(
    file_path: str, variant: str
) -> Optional[tuple[bytes, int, int, int]]:
    """
    Process an image file for the specified variant.

    Args:
        file_path: Path to the image file
        variant: One of "vision", "thumb", or "full"

    Returns:
        Tuple of (image_bytes, width, height, size_bytes) or None if processing fails
    """
    path = Path(file_path)
    if not path.exists():
        return None

    spec = VARIANT_SPECS[variant]
    max_dimension = spec["max_dimension"]
    quality = spec["quality"]

    try:
        with Image.open(path) as img:
            original_width, original_height = img.size

            # For "full" variant, return original file if it's already JPEG
            if variant == "full":
                # Read original file
                original_bytes = path.read_bytes()
                return (original_bytes, original_width, original_height, len(original_bytes))

            # Convert to RGB if necessary (handles RGBA, P mode, etc)
            if img.mode in ('RGBA', 'P', 'LA'):
                img = img.convert('RGB')
            elif img.mode != 'RGB':
                img = img.convert('RGB')

            # Resize if needed
            width, height = img.size
            if max_dimension and max(width, height) > max_dimension:
                if width > height:
                    new_width = max_dimension
                    new_height = int(height * (max_dimension / width))
                else:
                    new_height = max_dimension
                    new_width = int(width * (max_dimension / height))
                img = img.resize((new_width, new_height), Image.Resampling.LANCZOS)
                width, height = new_width, new_height

            # Save to JPEG in memory
            buffer = BytesIO()
            img.save(buffer, format='JPEG', quality=quality)
            buffer.seek(0)
            image_bytes = buffer.read()

            return (image_bytes, width, height, len(image_bytes))

    except Exception:
        return None


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
    variant: str = "vision",
    db_path: str = DB_PATH,
) -> list | dict[str, Any]:
    """
    Get attachment content at specified resolution variant.

    Use this tool when you need to view an image from a conversation.
    The get_messages tool returns metadata only - use this tool to see the actual image.

    Args:
        attachment_id: Attachment identifier (e.g., "att123" or just "123")
        variant: Resolution variant - "vision" (1568px, default), "thumb" (400px), or "full" (original)
        db_path: Path to chat.db (for testing)

    Returns:
        List with [metadata_string, Image] for images, or dict with error
    """
    # Validate variant
    if variant not in VALID_VARIANTS:
        return {
            "error": "validation_error",
            "message": f"Invalid variant '{variant}'. Must be one of: {', '.join(sorted(VALID_VARIANTS))}",
        }

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
                result = process_image_for_variant(filename, variant)
                if result:
                    image_bytes, width, height, size_bytes = result

                    # Build metadata string
                    size_human = _format_size(size_bytes)
                    metadata = f"{display_name} ({width}x{height}, {size_human})"

                    # Add warning for full variant if large
                    if variant == "full" and size_bytes > 200 * 1024:
                        metadata += f" [WARNING: Large file may impact performance]"

                    # Determine format for MCPImage
                    # For vision/thumb variants, we always output JPEG
                    # For full variant, preserve original format
                    if variant == "full":
                        # Try to determine format from file extension
                        ext = Path(filename).suffix.lower()
                        if ext in ('.jpg', '.jpeg'):
                            img_format = "jpeg"
                        elif ext == '.png':
                            img_format = "png"
                        elif ext == '.gif':
                            img_format = "gif"
                        elif ext == '.webp':
                            img_format = "webp"
                        elif ext in ('.heic', '.heif'):
                            # HEIC/HEIF need to be converted for compatibility
                            img_format = "jpeg"
                        else:
                            img_format = "jpeg"
                    else:
                        img_format = "jpeg"

                    return [
                        metadata,
                        MCPImage(data=image_bytes, format=img_format),
                    ]
                else:
                    return {
                        "error": "processing_failed",
                        "message": "Failed to process image",
                    }

            elif att_type == 'video':
                # Videos still use the old approach - return metadata about the video
                # with a thumbnail (videos can't be sent as MCPImage)
                return {
                    "error": "unsupported_type",
                    "message": "Video attachments are not yet supported with the new variant system. Use list_attachments to see video metadata.",
                    "type": att_type,
                    "filename": display_name,
                    "size": row['total_bytes'],
                }

            else:
                return {
                    "error": "unsupported_type",
                    "message": f"Attachment type '{att_type}' not supported. Only images are supported.",
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
