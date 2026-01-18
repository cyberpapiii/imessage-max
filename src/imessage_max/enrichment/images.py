"""Image processing for media enrichment."""

import base64
from io import BytesIO
from pathlib import Path
from typing import Optional, TypedDict

# Register HEIF opener with Pillow
import pillow_heif
pillow_heif.register_heif_opener()

from PIL import Image

# Thumbnail size for browsing (fits under 1MB MCP response limit)
THUMBNAIL_DIMENSION = 512
# Full resolution for detailed viewing (screenshots, etc.)
FULL_RESOLUTION = 1536
JPEG_QUALITY = 85


class ImageResult(TypedDict):
    """Result of image processing."""
    type: str
    base64: str
    filename: str


def process_image(file_path: str, max_dimension: int = THUMBNAIL_DIMENSION) -> Optional[ImageResult]:
    """
    Process an image file for embedding in API response.

    - Converts HEIC/PNG/etc to JPEG
    - Resizes to max dimension on long edge (default 512px for thumbnails)
    - Returns base64 encoded data

    Args:
        file_path: Path to the image file
        max_dimension: Maximum dimension for the long edge (default THUMBNAIL_DIMENSION=512)

    Returns:
        ImageResult dict with type, base64, filename, or None if processing fails
    """
    path = Path(file_path)

    if not path.exists():
        return None

    try:
        with Image.open(path) as img:
            # Convert to RGB if necessary (handles RGBA, P mode, etc)
            if img.mode in ('RGBA', 'P', 'LA'):
                img = img.convert('RGB')
            elif img.mode != 'RGB':
                img = img.convert('RGB')

            # Resize if needed
            width, height = img.size
            if max(width, height) > max_dimension:
                if width > height:
                    new_width = max_dimension
                    new_height = int(height * (max_dimension / width))
                else:
                    new_height = max_dimension
                    new_width = int(width * (max_dimension / height))
                img = img.resize((new_width, new_height), Image.Resampling.LANCZOS)

            # Save to JPEG in memory
            buffer = BytesIO()
            img.save(buffer, format='JPEG', quality=JPEG_QUALITY)
            buffer.seek(0)

            return ImageResult(
                type="image",
                base64=base64.b64encode(buffer.read()).decode('ascii'),
                filename=path.name,
            )

    except Exception:
        return None
