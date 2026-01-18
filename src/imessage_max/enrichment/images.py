"""Image processing for media enrichment."""

import base64
from io import BytesIO
from pathlib import Path
from typing import Optional, TypedDict

# Register HEIF opener with Pillow
import pillow_heif
pillow_heif.register_heif_opener()

from PIL import Image

MAX_DIMENSION = 1536
JPEG_QUALITY = 85


class ImageResult(TypedDict):
    """Result of image processing."""
    type: str
    base64: str
    filename: str


def process_image(file_path: str) -> Optional[ImageResult]:
    """
    Process an image file for embedding in API response.

    - Converts HEIC/PNG/etc to JPEG
    - Resizes to max 1536px on long edge
    - Returns base64 encoded data

    Args:
        file_path: Path to the image file

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
            if max(width, height) > MAX_DIMENSION:
                if width > height:
                    new_width = MAX_DIMENSION
                    new_height = int(height * (MAX_DIMENSION / width))
                else:
                    new_height = MAX_DIMENSION
                    new_width = int(width * (MAX_DIMENSION / height))
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
