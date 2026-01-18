"""Audio processing for media enrichment."""

import re
import subprocess
from pathlib import Path
from typing import Optional, TypedDict

import imageio_ffmpeg


class AudioResult(TypedDict):
    """Result of audio processing."""
    type: str
    duration_seconds: int
    filename: str


def process_audio(file_path: str) -> Optional[AudioResult]:
    """
    Process an audio file to extract duration.

    Args:
        file_path: Path to the audio file (CAF, M4A, etc)

    Returns:
        AudioResult dict with type, duration_seconds, filename,
        or None if processing fails
    """
    path = Path(file_path)

    if not path.exists():
        return None

    try:
        # Use ffmpeg to get duration from audio files
        # imageio_ffmpeg.count_frames_and_secs() doesn't work for audio-only files
        ffmpeg_path = imageio_ffmpeg.get_ffmpeg_exe()

        result = subprocess.run(
            [ffmpeg_path, "-i", file_path, "-f", "null", "-"],
            capture_output=True,
            text=True,
        )

        # Parse duration from stderr (format: Duration: HH:MM:SS.fraction)
        duration_match = re.search(
            r"Duration: (\d{2}):(\d{2}):(\d{2})\.(\d+)", result.stderr
        )

        if not duration_match:
            return None

        hours, minutes, seconds, fraction = duration_match.groups()
        duration = (
            int(hours) * 3600
            + int(minutes) * 60
            + int(seconds)
            + float(f"0.{fraction}")
        )

        if duration <= 0:
            return None

        return AudioResult(
            type="audio",
            duration_seconds=int(duration),
            filename=path.name,
        )

    except Exception:
        return None
