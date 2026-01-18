"""Tests for get_attachment tool."""

import pytest
from imessage_max.tools.get_attachment import get_attachment_impl


def test_get_attachment_requires_id(mock_db_path):
    """Test that attachment_id is required."""
    result = get_attachment_impl(attachment_id="", db_path=str(mock_db_path))

    assert "error" in result
    assert result["error"] == "validation_error"


def test_get_attachment_validates_id_format(mock_db_path):
    """Test that invalid ID format returns validation error."""
    result = get_attachment_impl(attachment_id="invalid", db_path=str(mock_db_path))

    assert "error" in result
    assert result["error"] == "validation_error"


def test_get_attachment_accepts_att_prefix(mock_db_path):
    """Test that 'attXXX' format is accepted."""
    # Will not find the attachment, but should not error on format
    result = get_attachment_impl(attachment_id="att123", db_path=str(mock_db_path))

    # Should fail with attachment_not_found, not validation_error
    assert "error" in result
    assert result["error"] == "attachment_not_found"


def test_get_attachment_accepts_numeric_id(mock_db_path):
    """Test that plain numeric ID is accepted."""
    result = get_attachment_impl(attachment_id="123", db_path=str(mock_db_path))

    # Should fail with attachment_not_found, not validation_error
    assert "error" in result
    assert result["error"] == "attachment_not_found"


def test_get_attachment_not_found(attachments_db):
    """Test error when attachment doesn't exist."""
    result = get_attachment_impl(
        attachment_id="att99999",
        db_path=str(attachments_db),
    )

    assert "error" in result
    assert result["error"] == "attachment_not_found"


def test_get_attachment_database_not_found():
    """Test error handling for missing database."""
    result = get_attachment_impl(
        attachment_id="att1",
        db_path="/nonexistent/path/chat.db",
    )

    assert "error" in result
    assert result["error"] == "database_not_found"


def test_get_attachment_file_not_on_disk(attachments_db):
    """Test error when attachment file doesn't exist on disk."""
    # The attachments_db fixture has paths that don't exist
    result = get_attachment_impl(
        attachment_id="att1",
        db_path=str(attachments_db),
    )

    assert "error" in result
    assert result["error"] == "attachment_unavailable"


def test_get_attachment_returns_full_resolution_image(attachments_db, tmp_path):
    """Test that images are returned at full resolution (1536px)."""
    import sqlite3
    from PIL import Image

    # Create a large test image
    img_path = tmp_path / "test_image.jpg"
    img = Image.new("RGB", (3000, 2000), color="red")
    img.save(img_path, "JPEG")

    # Update the attachment to point to our test image
    conn = sqlite3.connect(attachments_db)
    conn.execute(
        "UPDATE attachment SET filename = ? WHERE ROWID = 1",
        (str(img_path),)
    )
    conn.commit()
    conn.close()

    result = get_attachment_impl(
        attachment_id="att1",
        db_path=str(attachments_db),
    )

    assert "error" not in result
    assert result["type"] == "image"
    assert result["resolution"] == "full"
    assert "base64" in result

    # Verify dimensions (should be full resolution, not thumbnail)
    import base64
    from io import BytesIO
    decoded = base64.b64decode(result["base64"])
    resized = Image.open(BytesIO(decoded))
    # Full resolution is 1536px max
    assert max(resized.size) == 1536


def test_get_attachment_returns_full_resolution_video(attachments_db, tmp_path):
    """Test that videos are returned at full resolution."""
    import sqlite3
    import subprocess
    import imageio_ffmpeg

    # Create a large test video
    video_path = tmp_path / "test_video.mp4"
    ffmpeg_path = imageio_ffmpeg.get_ffmpeg_exe()
    subprocess.run([
        ffmpeg_path,
        "-f", "lavfi",
        "-i", "color=c=blue:size=3840x2160:duration=2",
        "-c:v", "libx264",
        "-t", "2",
        "-y",
        str(video_path)
    ], capture_output=True, check=True)

    # Update the video attachment to point to our test video
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

    assert "error" not in result
    assert result["type"] == "video"
    assert result["resolution"] == "full"
    assert "thumbnail_base64" in result
    assert "duration_seconds" in result

    # Verify thumbnail dimensions (should be full resolution, not thumbnail)
    import base64
    from PIL import Image
    from io import BytesIO
    decoded = base64.b64decode(result["thumbnail_base64"])
    img = Image.open(BytesIO(decoded))
    # Full resolution is 1536px max
    assert max(img.size) == 1536


def test_get_attachment_unsupported_type(attachments_db, tmp_path):
    """Test that non-image/video attachments return unsupported type error."""
    import sqlite3

    # Create a test PDF (just dummy content)
    pdf_path = tmp_path / "test.pdf"
    pdf_path.write_bytes(b"%PDF-1.4 dummy")

    # Update the PDF attachment to point to our test file
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

    assert "error" in result
    assert result["error"] == "unsupported_type"
    assert result["type"] == "pdf"


def test_get_attachment_includes_id_and_filename(attachments_db, tmp_path):
    """Test that response includes id and filename."""
    import sqlite3
    from PIL import Image

    img_path = tmp_path / "photo.jpg"
    img = Image.new("RGB", (100, 100), color="green")
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
        db_path=str(attachments_db),
    )

    assert "error" not in result
    assert result["id"] == "att1"
    assert result["filename"] == "IMG_001.jpg"  # Uses transfer_name from fixture
