"""Video processing for media enrichment."""

import base64
from io import BytesIO
from pathlib import Path
from typing import Optional, TypedDict

import imageio_ffmpeg
from PIL import Image

MAX_DIMENSION = 1536
JPEG_QUALITY = 85
FRAME_POSITION = 3  # Extract frame at 3 seconds (or earlier for short videos)


class VideoResult(TypedDict):
    """Result of video processing."""
    type: str
    thumbnail_base64: str
    duration_seconds: int
    filename: str


def process_video(file_path: str) -> Optional[VideoResult]:
    """
    Process a video file for embedding in API response.

    - Extracts a frame at ~3 seconds (or earlier if video is short)
    - Resizes to max 1536px on long edge
    - Returns base64 encoded JPEG thumbnail + duration

    Args:
        file_path: Path to the video file

    Returns:
        VideoResult dict with type, thumbnail_base64, duration_seconds, filename,
        or None if processing fails
    """
    path = Path(file_path)

    if not path.exists():
        return None

    try:
        # Get frame count and duration
        nframes, duration = imageio_ffmpeg.count_frames_and_secs(file_path)
        if duration is None or duration <= 0:
            return None

        # Determine frame position (3 seconds or 1/3 into video if shorter)
        frame_time = min(FRAME_POSITION, duration / 3)

        # Calculate which frame number to extract
        fps = nframes / duration if duration > 0 else 30
        target_frame = int(frame_time * fps)

        # Read frames to get the one we want
        gen = imageio_ffmpeg.read_frames(file_path)
        meta = next(gen)

        width, height = meta.get("size", meta.get("source_size", (0, 0)))
        if width == 0 or height == 0:
            return None

        # Skip to the target frame
        frame_data = None
        for i, frame in enumerate(gen):
            if i >= target_frame:
                frame_data = frame
                break
            # Safety: don't read more than necessary
            if i > target_frame + 10:
                break

        # If we couldn't get the target frame, try the first frame
        if frame_data is None:
            gen = imageio_ffmpeg.read_frames(file_path)
            next(gen)  # skip metadata
            frame_data = next(gen, None)

        if frame_data is None:
            return None

        # Convert raw RGB bytes to PIL Image
        img = Image.frombytes('RGB', (width, height), frame_data)

        # Resize if needed
        if max(width, height) > MAX_DIMENSION:
            if width > height:
                new_width = MAX_DIMENSION
                new_height = int(height * (MAX_DIMENSION / width))
            else:
                new_height = MAX_DIMENSION
                new_width = int(width * (MAX_DIMENSION / height))
            img = img.resize((new_width, new_height), Image.Resampling.LANCZOS)

        # Save to JPEG
        buffer = BytesIO()
        img.save(buffer, format='JPEG', quality=JPEG_QUALITY)
        buffer.seek(0)

        return VideoResult(
            type="video",
            thumbnail_base64=base64.b64encode(buffer.read()).decode('ascii'),
            duration_seconds=int(duration),
            filename=path.name,
        )

    except Exception:
        return None
