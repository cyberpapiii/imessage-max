"""Tests for audio enrichment."""

import pytest
from pathlib import Path
from imessage_max.enrichment.audio import process_audio


class TestProcessAudio:
    """Tests for process_audio function."""

    @pytest.fixture
    def sample_audio(self, tmp_path):
        """Create a minimal test audio file using ffmpeg."""
        import subprocess
        import imageio_ffmpeg

        audio_path = tmp_path / "voice.m4a"
        ffmpeg_path = imageio_ffmpeg.get_ffmpeg_exe()

        # Create a 15-second test audio (sine wave)
        subprocess.run([
            ffmpeg_path,
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=15",
            "-c:a", "aac",
            "-y",
            str(audio_path)
        ], capture_output=True, check=True)

        return audio_path

    def test_process_audio_returns_duration(self, sample_audio):
        """Audio processing should return duration in seconds."""
        result = process_audio(str(sample_audio))

        assert result is not None
        assert result["type"] == "audio"
        assert "duration_seconds" in result
        assert 14 <= result["duration_seconds"] <= 16
        assert result["filename"] == "voice.m4a"

    def test_process_caf_audio(self, tmp_path):
        """CAF (Core Audio Format) files should be processed."""
        import subprocess
        import imageio_ffmpeg

        audio_path = tmp_path / "Audio Message.caf"
        ffmpeg_path = imageio_ffmpeg.get_ffmpeg_exe()

        subprocess.run([
            ffmpeg_path,
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=10",
            "-c:a", "pcm_s16le",
            "-y",
            str(audio_path)
        ], capture_output=True, check=True)

        result = process_audio(str(audio_path))

        assert result is not None
        assert result["type"] == "audio"
        assert 9 <= result["duration_seconds"] <= 11

    def test_process_missing_audio_returns_none(self):
        """Missing audio files should return None."""
        result = process_audio("/nonexistent/audio.m4a")
        assert result is None

    def test_process_corrupt_audio_returns_none(self, tmp_path):
        """Corrupt audio files should return None."""
        audio_path = tmp_path / "corrupt.m4a"
        audio_path.write_bytes(b"not audio")

        result = process_audio(str(audio_path))
        assert result is None
