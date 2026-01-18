"""Tests for video enrichment."""

import pytest
import base64
from pathlib import Path
from imessage_max.enrichment.videos import process_video


class TestProcessVideo:
    """Tests for process_video function."""

    @pytest.fixture
    def sample_video(self, tmp_path):
        """Create a minimal test video using ffmpeg."""
        import subprocess
        import imageio_ffmpeg

        video_path = tmp_path / "test.mp4"
        ffmpeg_path = imageio_ffmpeg.get_ffmpeg_exe()

        # Create a 5-second test video with solid color
        subprocess.run([
            ffmpeg_path,
            "-f", "lavfi",
            "-i", "color=c=red:size=320x240:duration=5",
            "-c:v", "libx264",
            "-t", "5",
            "-y",
            str(video_path)
        ], capture_output=True, check=True)

        return video_path

    def test_process_video_extracts_frame(self, sample_video):
        """Video processing should extract a frame as thumbnail."""
        result = process_video(str(sample_video))

        assert result is not None
        assert result["type"] == "video"
        assert "thumbnail_base64" in result
        assert result["filename"] == "test.mp4"
        # Verify it's valid base64 JPEG
        decoded = base64.b64decode(result["thumbnail_base64"])
        assert decoded[:2] == b'\xff\xd8'

    def test_process_video_includes_duration(self, sample_video):
        """Video processing should include duration in seconds."""
        result = process_video(str(sample_video))

        assert result is not None
        assert "duration_seconds" in result
        # Our test video is 5 seconds
        assert 4 <= result["duration_seconds"] <= 6

    def test_process_video_resizes_thumbnail(self, tmp_path):
        """Large video thumbnails should be resized."""
        import subprocess
        import imageio_ffmpeg

        video_path = tmp_path / "large.mp4"
        ffmpeg_path = imageio_ffmpeg.get_ffmpeg_exe()

        # Create a 4K test video (3840x2160)
        subprocess.run([
            ffmpeg_path,
            "-f", "lavfi",
            "-i", "color=c=blue:size=3840x2160:duration=2",
            "-c:v", "libx264",
            "-t", "2",
            "-y",
            str(video_path)
        ], capture_output=True, check=True)

        result = process_video(str(video_path))

        assert result is not None
        # Check thumbnail dimensions
        decoded = base64.b64decode(result["thumbnail_base64"])
        from PIL import Image
        from io import BytesIO
        img = Image.open(BytesIO(decoded))
        assert max(img.size) <= 1536

    def test_process_missing_video_returns_none(self):
        """Missing video files should return None."""
        result = process_video("/nonexistent/video.mp4")
        assert result is None

    def test_process_corrupt_video_returns_none(self, tmp_path):
        """Corrupt video files should return None."""
        video_path = tmp_path / "corrupt.mp4"
        video_path.write_bytes(b"not a video")

        result = process_video(str(video_path))
        assert result is None
