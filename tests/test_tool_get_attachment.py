"""Tests for get_attachment tool."""

import pytest
import sqlite3
from io import BytesIO
from PIL import Image as PILImage

from fastmcp.utilities.types import Image as MCPImage

from imessage_max.tools.get_attachment import (
    get_attachment_impl,
    VALID_VARIANTS,
    VARIANT_SPECS,
    process_image_for_variant,
)


class TestVariantValidation:
    """Tests for variant parameter validation."""

    def test_validates_invalid_variant(self, mock_db_path):
        """Test that invalid variant returns validation error."""
        result = get_attachment_impl(
            attachment_id="att1",
            variant="invalid",
            db_path=str(mock_db_path),
        )

        assert isinstance(result, dict)
        assert result["error"] == "validation_error"
        assert "invalid" in result["message"].lower()
        assert "vision" in result["message"]

    def test_accepts_vision_variant(self, mock_db_path):
        """Test that 'vision' variant is accepted."""
        result = get_attachment_impl(
            attachment_id="att123",
            variant="vision",
            db_path=str(mock_db_path),
        )
        # Should not fail with variant validation error
        assert result.get("error") != "validation_error" or "variant" not in result.get("message", "")

    def test_accepts_thumb_variant(self, mock_db_path):
        """Test that 'thumb' variant is accepted."""
        result = get_attachment_impl(
            attachment_id="att123",
            variant="thumb",
            db_path=str(mock_db_path),
        )
        # Should not fail with variant validation error
        assert result.get("error") != "validation_error" or "variant" not in result.get("message", "")

    def test_accepts_full_variant(self, mock_db_path):
        """Test that 'full' variant is accepted."""
        result = get_attachment_impl(
            attachment_id="att123",
            variant="full",
            db_path=str(mock_db_path),
        )
        # Should not fail with variant validation error
        assert result.get("error") != "validation_error" or "variant" not in result.get("message", "")

    def test_default_variant_is_vision(self, attachments_db, tmp_path):
        """Test that default variant is 'vision' (1568px)."""
        # Create a large test image
        img_path = tmp_path / "test_image.jpg"
        img = PILImage.new("RGB", (3000, 2000), color="red")
        img.save(img_path, "JPEG")

        conn = sqlite3.connect(attachments_db)
        conn.execute(
            "UPDATE attachment SET filename = ? WHERE ROWID = 1",
            (str(img_path),)
        )
        conn.commit()
        conn.close()

        # Call without specifying variant (should default to vision)
        result = get_attachment_impl(
            attachment_id="att1",
            db_path=str(attachments_db),
        )

        assert isinstance(result, list)
        assert len(result) == 2
        # Check dimensions in metadata string - vision is 1568px
        metadata = result[0]
        assert "1568" in metadata


class TestAttachmentIdValidation:
    """Tests for attachment_id parameter validation."""

    def test_requires_id(self, mock_db_path):
        """Test that attachment_id is required."""
        result = get_attachment_impl(attachment_id="", db_path=str(mock_db_path))

        assert isinstance(result, dict)
        assert result["error"] == "validation_error"

    def test_validates_id_format(self, mock_db_path):
        """Test that invalid ID format returns validation error."""
        result = get_attachment_impl(attachment_id="invalid", db_path=str(mock_db_path))

        assert isinstance(result, dict)
        assert result["error"] == "validation_error"

    def test_accepts_att_prefix(self, mock_db_path):
        """Test that 'attXXX' format is accepted."""
        result = get_attachment_impl(attachment_id="att123", db_path=str(mock_db_path))

        # Should fail with attachment_not_found, not validation_error
        assert isinstance(result, dict)
        assert result["error"] == "attachment_not_found"

    def test_accepts_numeric_id(self, mock_db_path):
        """Test that plain numeric ID is accepted."""
        result = get_attachment_impl(attachment_id="123", db_path=str(mock_db_path))

        # Should fail with attachment_not_found, not validation_error
        assert isinstance(result, dict)
        assert result["error"] == "attachment_not_found"


class TestErrorHandling:
    """Tests for error handling."""

    def test_attachment_not_found(self, attachments_db):
        """Test error when attachment doesn't exist."""
        result = get_attachment_impl(
            attachment_id="att99999",
            db_path=str(attachments_db),
        )

        assert isinstance(result, dict)
        assert result["error"] == "attachment_not_found"

    def test_database_not_found(self):
        """Test error handling for missing database."""
        result = get_attachment_impl(
            attachment_id="att1",
            db_path="/nonexistent/path/chat.db",
        )

        assert isinstance(result, dict)
        assert result["error"] == "database_not_found"

    def test_file_not_on_disk(self, attachments_db):
        """Test error when attachment file doesn't exist on disk."""
        result = get_attachment_impl(
            attachment_id="att1",
            db_path=str(attachments_db),
        )

        assert isinstance(result, dict)
        assert result["error"] == "attachment_unavailable"


class TestVisionVariant:
    """Tests for vision variant (1568px, default)."""

    def test_returns_list_with_metadata_and_image(self, attachments_db, tmp_path):
        """Test that vision variant returns [metadata, MCPImage]."""
        img_path = tmp_path / "test_image.jpg"
        img = PILImage.new("RGB", (3000, 2000), color="red")
        img.save(img_path, "JPEG")

        conn = sqlite3.connect(attachments_db)
        conn.execute(
            "UPDATE attachment SET filename = ? WHERE ROWID = 1",
            (str(img_path),)
        )
        conn.commit()
        conn.close()

        result = get_attachment_impl(
            attachment_id="att1",
            variant="vision",
            db_path=str(attachments_db),
        )

        assert isinstance(result, list)
        assert len(result) == 2
        assert isinstance(result[0], str)
        assert isinstance(result[1], MCPImage)

    def test_resizes_to_1568px(self, attachments_db, tmp_path):
        """Test that vision variant resizes to 1568px max dimension."""
        img_path = tmp_path / "test_image.jpg"
        img = PILImage.new("RGB", (3000, 2000), color="red")
        img.save(img_path, "JPEG")

        conn = sqlite3.connect(attachments_db)
        conn.execute(
            "UPDATE attachment SET filename = ? WHERE ROWID = 1",
            (str(img_path),)
        )
        conn.commit()
        conn.close()

        result = get_attachment_impl(
            attachment_id="att1",
            variant="vision",
            db_path=str(attachments_db),
        )

        # Verify dimensions through the metadata string
        metadata = result[0]
        # 3000x2000 -> 1568x1045 (long edge scaled to 1568)
        assert "1568x" in metadata

    def test_metadata_includes_filename_and_size(self, attachments_db, tmp_path):
        """Test that metadata string includes filename and human-readable size."""
        img_path = tmp_path / "test_image.jpg"
        img = PILImage.new("RGB", (1000, 800), color="blue")
        img.save(img_path, "JPEG")

        conn = sqlite3.connect(attachments_db)
        conn.execute(
            "UPDATE attachment SET filename = ? WHERE ROWID = 1",
            (str(img_path),)
        )
        conn.commit()
        conn.close()

        result = get_attachment_impl(
            attachment_id="att1",
            variant="vision",
            db_path=str(attachments_db),
        )

        metadata = result[0]
        # Uses transfer_name from fixture
        assert "IMG_001.jpg" in metadata
        # Should have human-readable size
        assert "KB" in metadata or "MB" in metadata or "B" in metadata


class TestThumbVariant:
    """Tests for thumb variant (400px)."""

    def test_resizes_to_400px(self, attachments_db, tmp_path):
        """Test that thumb variant resizes to 400px max dimension."""
        img_path = tmp_path / "test_image.jpg"
        img = PILImage.new("RGB", (2000, 1500), color="green")
        img.save(img_path, "JPEG")

        conn = sqlite3.connect(attachments_db)
        conn.execute(
            "UPDATE attachment SET filename = ? WHERE ROWID = 1",
            (str(img_path),)
        )
        conn.commit()
        conn.close()

        result = get_attachment_impl(
            attachment_id="att1",
            variant="thumb",
            db_path=str(attachments_db),
        )

        assert isinstance(result, list)
        metadata = result[0]
        # 2000x1500 -> 400x300 (long edge scaled to 400)
        assert "400x" in metadata


class TestFullVariant:
    """Tests for full variant (original resolution)."""

    def test_preserves_original_dimensions(self, attachments_db, tmp_path):
        """Test that full variant preserves original dimensions."""
        img_path = tmp_path / "test_image.jpg"
        img = PILImage.new("RGB", (1234, 567), color="purple")
        img.save(img_path, "JPEG")

        conn = sqlite3.connect(attachments_db)
        conn.execute(
            "UPDATE attachment SET filename = ? WHERE ROWID = 1",
            (str(img_path),)
        )
        conn.commit()
        conn.close()

        result = get_attachment_impl(
            attachment_id="att1",
            variant="full",
            db_path=str(attachments_db),
        )

        assert isinstance(result, list)
        metadata = result[0]
        assert "1234x567" in metadata

    def test_warns_for_large_files(self, attachments_db, tmp_path):
        """Test that full variant includes warning for files > 200KB."""
        import numpy as np
        img_path = tmp_path / "large_image.jpg"
        # Create a larger image with random noise that will exceed 200KB
        # Solid colors compress very well, so we need random data
        random_data = np.random.randint(0, 256, (2000, 2000, 3), dtype=np.uint8)
        img = PILImage.fromarray(random_data)
        img.save(img_path, "JPEG", quality=95)

        conn = sqlite3.connect(attachments_db)
        conn.execute(
            "UPDATE attachment SET filename = ? WHERE ROWID = 1",
            (str(img_path),)
        )
        conn.commit()
        conn.close()

        result = get_attachment_impl(
            attachment_id="att1",
            variant="full",
            db_path=str(attachments_db),
        )

        assert isinstance(result, list)
        metadata = result[0]
        assert "WARNING" in metadata


class TestUnsupportedTypes:
    """Tests for unsupported attachment types."""

    def test_pdf_returns_unsupported(self, attachments_db, tmp_path):
        """Test that PDF attachments return unsupported type error."""
        pdf_path = tmp_path / "test.pdf"
        pdf_path.write_bytes(b"%PDF-1.4 dummy")

        conn = sqlite3.connect(attachments_db)
        conn.execute(
            "UPDATE attachment SET filename = ? WHERE ROWID = 3",
            (str(pdf_path),)
        )
        conn.commit()
        conn.close()

        result = get_attachment_impl(
            attachment_id="att3",
            db_path=str(attachments_db),
        )

        assert isinstance(result, dict)
        assert result["error"] == "unsupported_type"
        assert result["type"] == "pdf"

    def test_video_returns_unsupported(self, attachments_db, tmp_path):
        """Test that video attachments return unsupported type error."""
        # Create a dummy video file (doesn't need to be valid)
        video_path = tmp_path / "test.mp4"
        video_path.write_bytes(b"fake video content")

        conn = sqlite3.connect(attachments_db)
        conn.execute(
            "UPDATE attachment SET filename = ? WHERE ROWID = 2",
            (str(video_path),)
        )
        conn.commit()
        conn.close()

        result = get_attachment_impl(
            attachment_id="att2",
            db_path=str(attachments_db),
        )

        assert isinstance(result, dict)
        assert result["error"] == "unsupported_type"
        assert result["type"] == "video"


class TestProcessImageForVariant:
    """Tests for the process_image_for_variant helper function."""

    def test_vision_uses_1568_and_quality_80(self, tmp_path):
        """Test vision variant uses 1568px and 80% quality."""
        img_path = tmp_path / "test.jpg"
        img = PILImage.new("RGB", (3000, 2000), color="red")
        img.save(img_path, "JPEG")

        result = process_image_for_variant(str(img_path), "vision")

        assert result is not None
        image_bytes, width, height, size_bytes = result
        assert width == 1568
        assert height == 1045  # Proportional

    def test_thumb_uses_400_and_quality_75(self, tmp_path):
        """Test thumb variant uses 400px and 75% quality."""
        img_path = tmp_path / "test.jpg"
        img = PILImage.new("RGB", (2000, 1000), color="green")
        img.save(img_path, "JPEG")

        result = process_image_for_variant(str(img_path), "thumb")

        assert result is not None
        image_bytes, width, height, size_bytes = result
        assert width == 400
        assert height == 200  # Proportional

    def test_full_preserves_original(self, tmp_path):
        """Test full variant preserves original dimensions."""
        img_path = tmp_path / "test.jpg"
        img = PILImage.new("RGB", (800, 600), color="blue")
        img.save(img_path, "JPEG")

        result = process_image_for_variant(str(img_path), "full")

        assert result is not None
        image_bytes, width, height, size_bytes = result
        assert width == 800
        assert height == 600

    def test_returns_none_for_missing_file(self, tmp_path):
        """Test that missing file returns None."""
        result = process_image_for_variant(str(tmp_path / "nonexistent.jpg"), "vision")
        assert result is None


class TestVariantSpecs:
    """Tests for variant specification constants."""

    def test_valid_variants_set(self):
        """Test VALID_VARIANTS contains expected values."""
        assert VALID_VARIANTS == {"vision", "thumb", "full"}

    def test_variant_specs_vision(self):
        """Test vision variant specs."""
        assert VARIANT_SPECS["vision"]["max_dimension"] == 1568
        assert VARIANT_SPECS["vision"]["quality"] == 80

    def test_variant_specs_thumb(self):
        """Test thumb variant specs."""
        assert VARIANT_SPECS["thumb"]["max_dimension"] == 400
        assert VARIANT_SPECS["thumb"]["quality"] == 75

    def test_variant_specs_full(self):
        """Test full variant specs."""
        assert VARIANT_SPECS["full"]["max_dimension"] is None
        assert VARIANT_SPECS["full"]["quality"] is None
