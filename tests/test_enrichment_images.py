"""Tests for image enrichment."""

import pytest
import base64
from pathlib import Path
from imessage_max.enrichment.images import process_image, get_image_metadata


class TestProcessImage:
    """Tests for process_image function."""

    def test_process_jpeg_returns_base64(self, tmp_path):
        """JPEG images should be resized and returned as base64."""
        # Create a simple test image
        from PIL import Image
        img_path = tmp_path / "test.jpg"
        img = Image.new("RGB", (100, 100), color="red")
        img.save(img_path, "JPEG")

        result = process_image(str(img_path))

        assert result is not None
        assert result["type"] == "image"
        assert "base64" in result
        assert result["filename"] == "test.jpg"
        # Verify it's valid base64
        decoded = base64.b64decode(result["base64"])
        assert len(decoded) > 0

    def test_process_image_resizes_large_images_to_thumbnail(self, tmp_path):
        """Images larger than 512px should be resized to thumbnail size by default."""
        from PIL import Image
        img_path = tmp_path / "large.jpg"
        img = Image.new("RGB", (3000, 2000), color="blue")
        img.save(img_path, "JPEG")

        result = process_image(str(img_path))

        assert result is not None
        # Decode and check dimensions
        decoded = base64.b64decode(result["base64"])
        from io import BytesIO
        resized = Image.open(BytesIO(decoded))
        # Long edge should be capped at 512 (thumbnail)
        assert max(resized.size) <= 512

    def test_process_image_full_resolution(self, tmp_path):
        """Full resolution mode should cap at 1536px."""
        from PIL import Image
        from imessage_max.enrichment.images import FULL_RESOLUTION
        img_path = tmp_path / "large.jpg"
        img = Image.new("RGB", (3000, 2000), color="blue")
        img.save(img_path, "JPEG")

        result = process_image(str(img_path), max_dimension=FULL_RESOLUTION)

        assert result is not None
        decoded = base64.b64decode(result["base64"])
        from io import BytesIO
        resized = Image.open(BytesIO(decoded))
        # Long edge should be capped at 1536 (full resolution)
        assert max(resized.size) <= 1536

    def test_process_image_preserves_aspect_ratio(self, tmp_path):
        """Resizing should preserve aspect ratio."""
        from PIL import Image
        img_path = tmp_path / "wide.jpg"
        # 3000x1500 = 2:1 aspect ratio
        img = Image.new("RGB", (3000, 1500), color="green")
        img.save(img_path, "JPEG")

        result = process_image(str(img_path))

        decoded = base64.b64decode(result["base64"])
        from io import BytesIO
        resized = Image.open(BytesIO(decoded))
        # Should be 512x256 (maintaining 2:1 at thumbnail size)
        assert resized.size[0] == 512
        assert resized.size[1] == 256

    def test_process_png_converts_to_jpeg(self, tmp_path):
        """PNG images should be converted to JPEG."""
        from PIL import Image
        img_path = tmp_path / "test.png"
        img = Image.new("RGB", (100, 100), color="yellow")
        img.save(img_path, "PNG")

        result = process_image(str(img_path))

        assert result is not None
        assert result["type"] == "image"
        # Verify output is JPEG by checking magic bytes
        decoded = base64.b64decode(result["base64"])
        assert decoded[:2] == b'\xff\xd8'  # JPEG magic bytes

    def test_process_heic_converts_to_jpeg(self, tmp_path):
        """HEIC images should be converted to JPEG."""
        import pillow_heif
        from PIL import Image

        img_path = tmp_path / "test.heic"
        # Create a HEIC file using pillow_heif
        img = Image.new("RGB", (100, 100), color="purple")
        heif_file = pillow_heif.from_pillow(img)
        heif_file.save(str(img_path))

        result = process_image(str(img_path))

        assert result is not None
        assert result["type"] == "image"
        assert result["filename"] == "test.heic"
        # Verify output is JPEG
        decoded = base64.b64decode(result["base64"])
        assert decoded[:2] == b'\xff\xd8'

    def test_process_missing_file_returns_none(self):
        """Missing files should return None."""
        result = process_image("/nonexistent/path/image.jpg")
        assert result is None

    def test_process_corrupt_file_returns_none(self, tmp_path):
        """Corrupt image files should return None."""
        img_path = tmp_path / "corrupt.jpg"
        img_path.write_bytes(b"not an image")

        result = process_image(str(img_path))
        assert result is None


class TestGetImageMetadata:
    """Tests for get_image_metadata function."""

    def test_returns_metadata_for_jpeg(self, tmp_path):
        """JPEG images should return metadata without base64."""
        from PIL import Image
        img_path = tmp_path / "test.jpg"
        img = Image.new("RGB", (640, 480), color="red")
        img.save(img_path, "JPEG")

        result = get_image_metadata(str(img_path))

        assert result is not None
        assert result["type"] == "image"
        assert result["filename"] == "test.jpg"
        assert result["size_bytes"] > 0
        assert result["dimensions"]["width"] == 640
        assert result["dimensions"]["height"] == 480
        # Should NOT have base64
        assert "base64" not in result

    def test_returns_metadata_for_heic(self, tmp_path):
        """HEIC images should return metadata without base64."""
        import pillow_heif
        from PIL import Image

        img_path = tmp_path / "test.heic"
        img = Image.new("RGB", (1920, 1080), color="blue")
        heif_file = pillow_heif.from_pillow(img)
        heif_file.save(str(img_path))

        result = get_image_metadata(str(img_path))

        assert result is not None
        assert result["type"] == "image"
        assert result["filename"] == "test.heic"
        assert result["size_bytes"] > 0
        assert result["dimensions"]["width"] == 1920
        assert result["dimensions"]["height"] == 1080

    def test_missing_file_returns_none(self):
        """Missing files should return None."""
        result = get_image_metadata("/nonexistent/path/image.jpg")
        assert result is None

    def test_corrupt_file_returns_none(self, tmp_path):
        """Corrupt image files should return None."""
        img_path = tmp_path / "corrupt.jpg"
        img_path.write_bytes(b"not an image")

        result = get_image_metadata(str(img_path))
        assert result is None

    def test_dimensions_structure(self, tmp_path):
        """Dimensions should be a dict with width and height keys."""
        from PIL import Image
        img_path = tmp_path / "test.png"
        img = Image.new("RGB", (800, 600), color="green")
        img.save(img_path, "PNG")

        result = get_image_metadata(str(img_path))

        assert isinstance(result["dimensions"], dict)
        assert "width" in result["dimensions"]
        assert "height" in result["dimensions"]
        assert isinstance(result["dimensions"]["width"], int)
        assert isinstance(result["dimensions"]["height"], int)
