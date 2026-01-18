# Media Enrichment Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enhance `get_messages` to return fully-enriched context with viewable images/videos, link metadata, and audio duration.

**Architecture:** Create an `enrichment/` module with specialized processors for images, videos, audio, and links. The `get_messages` tool will call these processors in parallel after fetching messages, embedding results directly in the response.

**Tech Stack:** Pillow + pillow-heif (images), imageio-ffmpeg (video/audio), httpx + beautifulsoup4 (links)

---

## Task 1: Add Dependencies

**Files:**
- Modify: `pyproject.toml:15-20`

**Step 1: Add new dependencies**

```toml
dependencies = [
    "fastmcp>=0.4,<3",
    "pyobjc-framework-Contacts>=12.1",
    "phonenumbers>=8.13",
    "python-dateutil>=2.8",
    "Pillow>=10.0",
    "pillow-heif>=0.16",
    "imageio-ffmpeg>=0.5",
    "httpx>=0.27",
    "beautifulsoup4>=4.12",
]
```

**Step 2: Install updated dependencies**

Run: `uv pip install -e ".[dev]"`
Expected: All packages install successfully

**Step 3: Verify imports work**

Run: `python -c "from PIL import Image; import pillow_heif; import imageio_ffmpeg; import httpx; from bs4 import BeautifulSoup; print('OK')"`
Expected: Prints "OK"

**Step 4: Commit**

```bash
git add pyproject.toml uv.lock
git commit -m "deps: Add Pillow, imageio-ffmpeg, httpx, beautifulsoup4 for media enrichment"
```

---

## Task 2: Create Image Processor

**Files:**
- Create: `src/imessage_max/enrichment/__init__.py`
- Create: `src/imessage_max/enrichment/images.py`
- Create: `tests/test_enrichment_images.py`

**Step 1: Create enrichment package init**

```python
"""Media enrichment pipeline for iMessage Max."""

from .images import process_image
from .videos import process_video
from .audio import process_audio
from .links import enrich_links

__all__ = ["process_image", "process_video", "process_audio", "enrich_links"]
```

Note: This will error until we create all modules. That's OK - create the file now.

**Step 2: Write the failing test for image processing**

```python
"""Tests for image enrichment."""

import pytest
import base64
from pathlib import Path
from imessage_max.enrichment.images import process_image


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

    def test_process_image_resizes_large_images(self, tmp_path):
        """Images larger than 1536px should be resized."""
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
        # Long edge should be capped at 1536
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
        # Should be 1536x768 (maintaining 2:1)
        assert resized.size[0] == 1536
        assert resized.size[1] == 768

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
```

**Step 3: Run test to verify it fails**

Run: `pytest tests/test_enrichment_images.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'imessage_max.enrichment'"

**Step 4: Write minimal image processor implementation**

```python
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
```

**Step 5: Run tests to verify they pass**

Run: `pytest tests/test_enrichment_images.py -v`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add src/imessage_max/enrichment/ tests/test_enrichment_images.py
git commit -m "feat(enrichment): Add image processor with HEIC support and resizing"
```

---

## Task 3: Add HEIC Test

**Files:**
- Modify: `tests/test_enrichment_images.py`

**Step 1: Write HEIC test**

Add to the test class:

```python
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
```

**Step 2: Run test**

Run: `pytest tests/test_enrichment_images.py::TestProcessImage::test_process_heic_converts_to_jpeg -v`
Expected: PASS (pillow_heif opener is already registered)

**Step 3: Commit**

```bash
git add tests/test_enrichment_images.py
git commit -m "test(enrichment): Add HEIC conversion test"
```

---

## Task 4: Create Video Processor

**Files:**
- Create: `src/imessage_max/enrichment/videos.py`
- Create: `tests/test_enrichment_videos.py`

**Step 1: Write the failing test for video processing**

```python
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
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_enrichment_videos.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'imessage_max.enrichment.videos'"

**Step 3: Write minimal video processor implementation**

```python
"""Video processing for media enrichment."""

import base64
import subprocess
import tempfile
from io import BytesIO
from pathlib import Path
from typing import Optional, TypedDict

import imageio_ffmpeg
from PIL import Image

MAX_DIMENSION = 1536
JPEG_QUALITY = 85
FRAME_POSITION = 3  # Extract frame at 3 seconds


class VideoResult(TypedDict):
    """Result of video processing."""
    type: str
    thumbnail_base64: str
    duration_seconds: int
    filename: str


def _get_duration(file_path: str) -> Optional[float]:
    """Get video duration in seconds using ffprobe."""
    ffprobe_path = imageio_ffmpeg.get_ffmpeg_exe().replace("ffmpeg", "ffprobe")

    try:
        result = subprocess.run(
            [
                ffprobe_path,
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                file_path
            ],
            capture_output=True,
            text=True,
            timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            return float(result.stdout.strip())
    except (subprocess.TimeoutExpired, ValueError):
        pass

    return None


def _extract_frame(file_path: str, position: float) -> Optional[bytes]:
    """Extract a single frame from video at given position."""
    ffmpeg_path = imageio_ffmpeg.get_ffmpeg_exe()

    try:
        result = subprocess.run(
            [
                ffmpeg_path,
                "-ss", str(position),
                "-i", file_path,
                "-vframes", "1",
                "-f", "image2pipe",
                "-vcodec", "png",
                "-"
            ],
            capture_output=True,
            timeout=30
        )
        if result.returncode == 0 and result.stdout:
            return result.stdout
    except subprocess.TimeoutExpired:
        pass

    return None


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
        # Get duration
        duration = _get_duration(file_path)
        if duration is None:
            return None

        # Determine frame position (3 seconds or 1/3 into video if shorter)
        frame_pos = min(FRAME_POSITION, duration / 3)

        # Extract frame
        frame_data = _extract_frame(file_path, frame_pos)
        if frame_data is None:
            return None

        # Process frame (resize, convert to JPEG)
        with Image.open(BytesIO(frame_data)) as img:
            if img.mode != 'RGB':
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
```

**Step 4: Run tests to verify they pass**

Run: `pytest tests/test_enrichment_videos.py -v`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/imessage_max/enrichment/videos.py tests/test_enrichment_videos.py
git commit -m "feat(enrichment): Add video processor with frame extraction and duration"
```

---

## Task 5: Create Audio Processor

**Files:**
- Create: `src/imessage_max/enrichment/audio.py`
- Create: `tests/test_enrichment_audio.py`

**Step 1: Write the failing test for audio processing**

```python
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
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_enrichment_audio.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'imessage_max.enrichment.audio'"

**Step 3: Write minimal audio processor implementation**

```python
"""Audio processing for media enrichment."""

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

    ffprobe_path = imageio_ffmpeg.get_ffmpeg_exe().replace("ffmpeg", "ffprobe")

    try:
        result = subprocess.run(
            [
                ffprobe_path,
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                file_path
            ],
            capture_output=True,
            text=True,
            timeout=10
        )

        if result.returncode == 0 and result.stdout.strip():
            duration = float(result.stdout.strip())
            return AudioResult(
                type="audio",
                duration_seconds=int(duration),
                filename=path.name,
            )

    except (subprocess.TimeoutExpired, ValueError):
        pass

    return None
```

**Step 4: Run tests to verify they pass**

Run: `pytest tests/test_enrichment_audio.py -v`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/imessage_max/enrichment/audio.py tests/test_enrichment_audio.py
git commit -m "feat(enrichment): Add audio processor for voice note duration"
```

---

## Task 6: Create Link Enrichment

**Files:**
- Create: `src/imessage_max/enrichment/links.py`
- Create: `tests/test_enrichment_links.py`

**Step 1: Write the failing test for link enrichment**

```python
"""Tests for link enrichment."""

import pytest
from imessage_max.enrichment.links import enrich_link, enrich_links


class TestEnrichLink:
    """Tests for enrich_link function."""

    def test_enrich_link_extracts_og_tags(self, httpx_mock):
        """Should extract Open Graph title and description."""
        httpx_mock.add_response(
            url="https://example.com/article",
            html='''
            <html>
            <head>
                <meta property="og:title" content="Test Article Title">
                <meta property="og:description" content="This is the article description.">
            </head>
            <body></body>
            </html>
            '''
        )

        result = enrich_link("https://example.com/article")

        assert result["url"] == "https://example.com/article"
        assert result["title"] == "Test Article Title"
        assert result["description"] == "This is the article description."
        assert result["domain"] == "example.com"

    def test_enrich_link_falls_back_to_title_tag(self, httpx_mock):
        """Should fall back to <title> if no OG title."""
        httpx_mock.add_response(
            url="https://example.com/page",
            html='''
            <html>
            <head>
                <title>Page Title</title>
            </head>
            <body></body>
            </html>
            '''
        )

        result = enrich_link("https://example.com/page")

        assert result["title"] == "Page Title"
        assert result["domain"] == "example.com"

    def test_enrich_link_handles_missing_metadata(self, httpx_mock):
        """Should return minimal data when no metadata found."""
        httpx_mock.add_response(
            url="https://example.com/bare",
            html="<html><body>Just content</body></html>"
        )

        result = enrich_link("https://example.com/bare")

        assert result["url"] == "https://example.com/bare"
        assert result["domain"] == "example.com"
        assert result.get("title") is None
        assert result.get("description") is None

    def test_enrich_link_handles_timeout(self, httpx_mock):
        """Should return minimal data on timeout."""
        import httpx
        httpx_mock.add_exception(httpx.TimeoutException("timeout"))

        result = enrich_link("https://slow.example.com/page")

        assert result["url"] == "https://slow.example.com/page"
        assert result["domain"] == "slow.example.com"

    def test_enrich_link_handles_error(self, httpx_mock):
        """Should return minimal data on HTTP error."""
        httpx_mock.add_response(url="https://example.com/404", status_code=404)

        result = enrich_link("https://example.com/404")

        assert result["url"] == "https://example.com/404"
        assert result["domain"] == "example.com"


class TestEnrichLinks:
    """Tests for enrich_links batch function."""

    def test_enrich_links_processes_multiple(self, httpx_mock):
        """Should process multiple links in parallel."""
        httpx_mock.add_response(
            url="https://a.com/",
            html='<html><head><meta property="og:title" content="A"></head></html>'
        )
        httpx_mock.add_response(
            url="https://b.com/",
            html='<html><head><meta property="og:title" content="B"></head></html>'
        )

        results = enrich_links(["https://a.com/", "https://b.com/"])

        assert len(results) == 2
        assert results[0]["title"] == "A"
        assert results[1]["title"] == "B"

    def test_enrich_links_handles_empty_list(self):
        """Should return empty list for empty input."""
        results = enrich_links([])
        assert results == []
```

**Step 2: Add pytest-httpx to dev dependencies**

In `pyproject.toml`, update:

```toml
[project.optional-dependencies]
dev = [
    "pytest>=7.0",
    "pytest-asyncio>=0.21",
    "pytest-httpx>=0.30",
]
```

Run: `uv pip install -e ".[dev]"`

**Step 3: Run test to verify it fails**

Run: `pytest tests/test_enrichment_links.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'imessage_max.enrichment.links'"

**Step 4: Write minimal link enrichment implementation**

```python
"""Link enrichment for media enrichment."""

from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional, TypedDict
from urllib.parse import urlparse

import httpx
from bs4 import BeautifulSoup

TIMEOUT = 3.0  # seconds
MAX_WORKERS = 4


class LinkResult(TypedDict, total=False):
    """Result of link enrichment."""
    url: str
    domain: str
    title: Optional[str]
    description: Optional[str]


def enrich_link(url: str) -> LinkResult:
    """
    Fetch Open Graph metadata for a URL.

    Args:
        url: The URL to enrich

    Returns:
        LinkResult dict with url, domain, and optional title/description
    """
    parsed = urlparse(url)
    result: LinkResult = {
        "url": url,
        "domain": parsed.netloc,
    }

    try:
        with httpx.Client(timeout=TIMEOUT, follow_redirects=True) as client:
            response = client.get(url, headers={"User-Agent": "Mozilla/5.0"})
            response.raise_for_status()

            soup = BeautifulSoup(response.text, 'html.parser')

            # Try OG tags first
            og_title = soup.find("meta", property="og:title")
            if og_title and og_title.get("content"):
                result["title"] = og_title["content"]
            else:
                # Fall back to <title>
                title_tag = soup.find("title")
                if title_tag and title_tag.string:
                    result["title"] = title_tag.string.strip()

            og_desc = soup.find("meta", property="og:description")
            if og_desc and og_desc.get("content"):
                result["description"] = og_desc["content"]
            else:
                # Fall back to meta description
                meta_desc = soup.find("meta", attrs={"name": "description"})
                if meta_desc and meta_desc.get("content"):
                    result["description"] = meta_desc["content"]

    except Exception:
        # Return minimal result on any error
        pass

    return result


def enrich_links(urls: list[str]) -> list[LinkResult]:
    """
    Enrich multiple links in parallel.

    Args:
        urls: List of URLs to enrich

    Returns:
        List of LinkResult dicts in same order as input
    """
    if not urls:
        return []

    results: dict[int, LinkResult] = {}

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        future_to_idx = {
            executor.submit(enrich_link, url): idx
            for idx, url in enumerate(urls)
        }

        for future in as_completed(future_to_idx):
            idx = future_to_idx[future]
            try:
                results[idx] = future.result()
            except Exception:
                # Return minimal result on failure
                results[idx] = {"url": urls[idx], "domain": urlparse(urls[idx]).netloc}

    return [results[i] for i in range(len(urls))]
```

**Step 5: Run tests to verify they pass**

Run: `pytest tests/test_enrichment_links.py -v`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add src/imessage_max/enrichment/links.py tests/test_enrichment_links.py pyproject.toml
git commit -m "feat(enrichment): Add link enrichment with OG metadata extraction"
```

---

## Task 7: Update Enrichment Package Init

**Files:**
- Modify: `src/imessage_max/enrichment/__init__.py`

**Step 1: Update init to export all processors**

```python
"""Media enrichment pipeline for iMessage Max."""

from .images import process_image
from .videos import process_video
from .audio import process_audio
from .links import enrich_link, enrich_links

__all__ = [
    "process_image",
    "process_video",
    "process_audio",
    "enrich_link",
    "enrich_links",
]
```

**Step 2: Verify imports work**

Run: `python -c "from imessage_max.enrichment import process_image, process_video, process_audio, enrich_links; print('OK')"`
Expected: Prints "OK"

**Step 3: Run all enrichment tests**

Run: `pytest tests/test_enrichment_*.py -v`
Expected: All tests PASS

**Step 4: Commit**

```bash
git add src/imessage_max/enrichment/__init__.py
git commit -m "feat(enrichment): Export all processors from package"
```

---

## Task 8: Add Attachment Query to get_messages

**Files:**
- Modify: `src/imessage_max/queries.py`
- Create: `tests/test_queries_attachments.py`

**Step 1: Write the failing test**

```python
"""Tests for attachment queries."""

import pytest
import sqlite3
from imessage_max.queries import get_attachments_for_messages


@pytest.fixture
def db_with_attachments(mock_db_path):
    """Create database with messages and attachments."""
    conn = sqlite3.connect(mock_db_path)
    conn.executescript("""
        INSERT INTO handle (ROWID, id, service) VALUES
            (1, '+19175551234', 'iMessage');

        INSERT INTO chat (ROWID, guid, display_name, service_name) VALUES
            (1, 'iMessage;+;chat123', NULL, 'iMessage');

        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
            (1, 1);

        INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, cache_has_attachments) VALUES
            (1, 'msg1', 'Photo', 1, 789100000000000000, 0, 1),
            (2, 'msg2', 'No attachment', 1, 789100100000000000, 0, 0),
            (3, 'msg3', 'Video', 1, 789100200000000000, 0, 1);

        INSERT INTO chat_message_join (chat_id, message_id) VALUES
            (1, 1), (1, 2), (1, 3);

        INSERT INTO attachment (ROWID, guid, filename, mime_type, uti, total_bytes) VALUES
            (1, 'att1', '~/Library/Messages/Attachments/IMG.HEIC', 'image/heic', 'public.heic', 2048000),
            (2, 'att2', '~/Library/Messages/Attachments/VID.mov', 'video/quicktime', 'public.movie', 15000000);

        INSERT INTO message_attachment_join (message_id, attachment_id) VALUES
            (1, 1),
            (3, 2);
    """)
    conn.close()
    return mock_db_path


class TestGetAttachmentsForMessages:
    """Tests for get_attachments_for_messages function."""

    def test_returns_attachments_grouped_by_message(self, db_with_attachments):
        """Should return attachments grouped by message ID."""
        conn = sqlite3.connect(db_with_attachments)
        conn.row_factory = sqlite3.Row

        result = get_attachments_for_messages(conn, [1, 2, 3])
        conn.close()

        assert 1 in result
        assert 2 not in result  # No attachment
        assert 3 in result

        assert result[1][0]["filename"].endswith("IMG.HEIC")
        assert result[1][0]["mime_type"] == "image/heic"

        assert result[3][0]["filename"].endswith("VID.mov")

    def test_returns_empty_for_no_messages(self, db_with_attachments):
        """Should return empty dict for empty message list."""
        conn = sqlite3.connect(db_with_attachments)
        conn.row_factory = sqlite3.Row

        result = get_attachments_for_messages(conn, [])
        conn.close()

        assert result == {}
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_queries_attachments.py -v`
Expected: FAIL with "cannot import name 'get_attachments_for_messages'"

**Step 3: Add the attachment query function**

Add to `src/imessage_max/queries.py`:

```python
def get_attachments_for_messages(
    conn: sqlite3.Connection,
    message_ids: list[int]
) -> dict[int, list[dict]]:
    """Get attachments grouped by message ID.

    Args:
        conn: Database connection
        message_ids: List of message ROWIDs to fetch attachments for

    Returns:
        Dict mapping message_id to list of attachment dicts
    """
    if not message_ids:
        return {}

    placeholders = ','.join('?' * len(message_ids))
    cursor = conn.execute(f"""
        SELECT
            maj.message_id,
            a.ROWID as id,
            a.filename,
            a.mime_type,
            a.uti,
            a.total_bytes
        FROM attachment a
        JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
        WHERE maj.message_id IN ({placeholders})
    """, tuple(message_ids))

    attachments: dict[int, list[dict]] = {}
    for row in cursor.fetchall():
        msg_id = row['message_id']
        if msg_id not in attachments:
            attachments[msg_id] = []
        attachments[msg_id].append({
            'id': row['id'],
            'filename': row['filename'],
            'mime_type': row['mime_type'],
            'uti': row['uti'],
            'total_bytes': row['total_bytes'],
        })

    return attachments
```

**Step 4: Run test to verify it passes**

Run: `pytest tests/test_queries_attachments.py -v`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/imessage_max/queries.py tests/test_queries_attachments.py
git commit -m "feat(queries): Add get_attachments_for_messages function"
```

---

## Task 9: Integrate Enrichment into get_messages

**Files:**
- Modify: `src/imessage_max/tools/get_messages.py`
- Modify: `tests/test_tool_get_messages.py`

**Step 1: Write the integration test**

Add to `tests/test_tool_get_messages.py`:

```python
class TestGetMessagesEnrichment:
    """Tests for media enrichment in get_messages."""

    @pytest.fixture
    def db_with_media(self, mock_db_path):
        """Create database with messages containing attachments and links."""
        conn = sqlite3.connect(mock_db_path)
        conn.executescript("""
            INSERT INTO handle (ROWID, id, service) VALUES
                (1, '+19175551234', 'iMessage');

            INSERT INTO chat (ROWID, guid, display_name, service_name) VALUES
                (1, 'iMessage;+;chat123', NULL, 'iMessage');

            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
                (1, 1);

            INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, cache_has_attachments) VALUES
                (1, 'msg1', 'Check this out https://example.com/article', 1, 789100000000000000, 0, 1);

            INSERT INTO chat_message_join (chat_id, message_id) VALUES
                (1, 1);

            INSERT INTO attachment (ROWID, guid, filename, mime_type, uti, total_bytes) VALUES
                (1, 'att1', '/tmp/test_image.jpg', 'image/jpeg', 'public.jpeg', 102400);

            INSERT INTO message_attachment_join (message_id, attachment_id) VALUES
                (1, 1);
        """)
        conn.close()

        # Create an actual image file for the test
        from PIL import Image
        img = Image.new("RGB", (100, 100), color="red")
        img.save("/tmp/test_image.jpg", "JPEG")

        return mock_db_path

    def test_get_messages_includes_media(self, db_with_media, httpx_mock):
        """Messages should include processed media."""
        httpx_mock.add_response(
            url="https://example.com/article",
            html='<html><head><meta property="og:title" content="Article Title"></head></html>'
        )

        result = get_messages_impl(chat_id="chat1", db_path=db_with_media)

        assert "messages" in result
        msg = result["messages"][0]

        # Check media array exists with processed image
        assert "media" in msg
        assert len(msg["media"]) == 1
        assert msg["media"][0]["type"] == "image"
        assert "base64" in msg["media"][0]

        # Check links array exists with enriched data
        assert "links" in msg
        assert len(msg["links"]) == 1
        assert msg["links"][0]["title"] == "Article Title"

    def test_get_messages_handles_missing_attachment_file(self, mock_db_path):
        """Missing attachment files should go to attachments array."""
        conn = sqlite3.connect(mock_db_path)
        conn.executescript("""
            INSERT INTO handle (ROWID, id, service) VALUES (1, '+19175551234', 'iMessage');
            INSERT INTO chat (ROWID, guid, display_name, service_name) VALUES (1, 'chat1', NULL, 'iMessage');
            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1);
            INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, cache_has_attachments)
                VALUES (1, 'msg1', 'Photo', 1, 789100000000000000, 0, 1);
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1);
            INSERT INTO attachment (ROWID, guid, filename, mime_type, uti, total_bytes)
                VALUES (1, 'att1', '/nonexistent/image.jpg', 'image/jpeg', 'public.jpeg', 102400);
            INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (1, 1);
        """)
        conn.close()

        result = get_messages_impl(chat_id="chat1", db_path=mock_db_path)

        msg = result["messages"][0]
        # Should be in attachments (fallback), not media
        assert "attachments" in msg
        assert len(msg["attachments"]) == 1
        assert msg["attachments"][0]["filename"] == "image.jpg"
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_tool_get_messages.py::TestGetMessagesEnrichment -v`
Expected: FAIL (media not yet included in response)

**Step 3: Update get_messages_impl with enrichment**

This is a larger change. Key modifications to `src/imessage_max/tools/get_messages.py`:

1. Import enrichment functions
2. Fetch attachments after messages
3. Process images/videos in parallel
4. Enrich links in parallel
5. Add `media`, `links`, `attachments` to message response

See the detailed implementation below. Add these imports at the top:

```python
from concurrent.futures import ThreadPoolExecutor
from ..queries import get_chat_participants, get_messages_for_chat, get_reactions_for_messages, get_attachments_for_messages
from ..enrichment import process_image, process_video, process_audio, enrich_links
```

Add this helper function:

```python
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
```

In the main function, after building the messages list but before `_assign_sessions`, add enrichment processing:

```python
            # Fetch attachments for messages
            message_row_ids = [row['id'] for row in message_rows]
            attachments_map = get_attachments_for_messages(conn, message_row_ids)

            # Collect all items to process
            image_tasks = []  # (msg_idx, attachment)
            video_tasks = []  # (msg_idx, attachment)
            audio_tasks = []  # (msg_idx, attachment)
            link_urls = []    # All unique URLs to enrich
            url_to_msg_indices = {}  # URL -> list of msg indices

            for idx, (msg, row) in enumerate(zip(messages, message_rows)):
                msg_id = row['id']

                # Collect attachment processing tasks
                if msg_id in attachments_map:
                    for att in attachments_map[msg_id]:
                        att_type = _get_attachment_type(att['mime_type'], att['uti'])
                        filename = att['filename']
                        if filename:
                            # Expand ~ in path
                            if filename.startswith('~'):
                                import os
                                filename = os.path.expanduser(filename)

                            if att_type == 'image':
                                image_tasks.append((idx, att, filename))
                            elif att_type == 'video':
                                video_tasks.append((idx, att, filename))
                            elif att_type == 'audio':
                                audio_tasks.append((idx, att, filename))
                            else:
                                # Other types go directly to attachments
                                if 'attachments' not in msg:
                                    msg['attachments'] = []
                                msg['attachments'].append({
                                    'type': att_type,
                                    'filename': att['filename'].split('/')[-1] if att['filename'] else None,
                                    'size': att['total_bytes'],
                                })

                # Collect links for enrichment
                if 'links' in msg:
                    for url in msg['links']:
                        if url not in url_to_msg_indices:
                            url_to_msg_indices[url] = []
                            link_urls.append(url)
                        url_to_msg_indices[url].append(idx)
                    # Clear raw links, will be replaced with enriched
                    del msg['links']

            # Process media in parallel
            MAX_IMAGES = 10
            processed_count = 0

            with ThreadPoolExecutor(max_workers=4) as executor:
                # Process images
                image_futures = {
                    executor.submit(process_image, path): (idx, att)
                    for idx, att, path in image_tasks[:MAX_IMAGES]
                }

                for future in image_futures:
                    idx, att = image_futures[future]
                    result = future.result()
                    if result:
                        if 'media' not in messages[idx]:
                            messages[idx]['media'] = []
                        messages[idx]['media'].append(result)
                        processed_count += 1
                    else:
                        # Failed - add to attachments
                        if 'attachments' not in messages[idx]:
                            messages[idx]['attachments'] = []
                        messages[idx]['attachments'].append({
                            'type': 'image',
                            'filename': att['filename'].split('/')[-1] if att['filename'] else None,
                            'size': att['total_bytes'],
                        })

                # Process videos
                video_futures = {
                    executor.submit(process_video, path): (idx, att)
                    for idx, att, path in video_tasks[:MAX_IMAGES - processed_count]
                }

                for future in video_futures:
                    idx, att = video_futures[future]
                    result = future.result()
                    if result:
                        if 'media' not in messages[idx]:
                            messages[idx]['media'] = []
                        messages[idx]['media'].append(result)
                        processed_count += 1
                    else:
                        if 'attachments' not in messages[idx]:
                            messages[idx]['attachments'] = []
                        messages[idx]['attachments'].append({
                            'type': 'video',
                            'filename': att['filename'].split('/')[-1] if att['filename'] else None,
                            'size': att['total_bytes'],
                        })

                # Process audio (just duration, always goes to attachments)
                audio_futures = {
                    executor.submit(process_audio, path): (idx, att)
                    for idx, att, path in audio_tasks
                }

                for future in audio_futures:
                    idx, att = audio_futures[future]
                    result = future.result()
                    if 'attachments' not in messages[idx]:
                        messages[idx]['attachments'] = []
                    if result:
                        messages[idx]['attachments'].append(result)
                    else:
                        messages[idx]['attachments'].append({
                            'type': 'audio',
                            'filename': att['filename'].split('/')[-1] if att['filename'] else None,
                            'size': att['total_bytes'],
                        })

            # Enrich links
            if link_urls:
                enriched = enrich_links(link_urls)
                for url, link_data in zip(link_urls, enriched):
                    for msg_idx in url_to_msg_indices[url]:
                        if 'links' not in messages[msg_idx]:
                            messages[msg_idx]['links'] = []
                        messages[msg_idx]['links'].append(link_data)

            # Add truncation info if needed
            total_media = len(image_tasks) + len(video_tasks)
            media_truncated = total_media > MAX_IMAGES
```

Also update the response dict to include media stats:

```python
            response = {
                "chat": {
                    "id": f"chat{numeric_chat_id}",
                    "name": display_name,
                },
                "people": people,
                "messages": messages,
                "sessions": sessions_summary,
                "more": len(messages) == limit,
                "cursor": None,
            }

            if media_truncated:
                response["media_truncated"] = True
                response["media_total"] = total_media
                response["media_included"] = MAX_IMAGES
```

**Step 4: Run tests**

Run: `pytest tests/test_tool_get_messages.py -v`
Expected: All tests PASS

**Step 5: Run full test suite**

Run: `pytest tests/ -v`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add src/imessage_max/tools/get_messages.py tests/test_tool_get_messages.py
git commit -m "feat(get_messages): Integrate media enrichment pipeline"
```

---

## Task 10: Integration Test with Real Data

**Files:**
- Modify: `tests/integration/test_real_database.py`

**Step 1: Add integration test for enrichment**

```python
@pytest.mark.integration
class TestGetMessagesEnrichmentIntegration:
    """Integration tests for media enrichment with real database."""

    def test_get_messages_enriches_recent_messages(self):
        """Should enrich images and links in recent messages."""
        from imessage_max.tools import get_messages_impl

        # Get messages from last 24 hours from any chat
        from imessage_max.tools.list_chats import list_chats_impl
        chats = list_chats_impl(limit=1)

        if not chats.get("chats"):
            pytest.skip("No chats available")

        chat_id = chats["chats"][0]["id"]
        result = get_messages_impl(chat_id=chat_id, since="24h", limit=10)

        assert "messages" in result
        # Just verify the structure is correct - media/links/attachments may or may not exist
        for msg in result["messages"]:
            if "media" in msg:
                for m in msg["media"]:
                    assert "type" in m
                    if m["type"] == "image":
                        assert "base64" in m
                    elif m["type"] == "video":
                        assert "thumbnail_base64" in m
                        assert "duration_seconds" in m

            if "links" in msg:
                for link in msg["links"]:
                    assert "url" in link
                    assert "domain" in link

            if "attachments" in msg:
                for att in msg["attachments"]:
                    assert "type" in att
                    assert "filename" in att
```

**Step 2: Run integration test**

Run: `pytest tests/integration/ --real-db -v`
Expected: PASS (or skip if no recent messages with media)

**Step 3: Commit**

```bash
git add tests/integration/test_real_database.py
git commit -m "test(integration): Add enrichment integration test"
```

---

## Task 11: Final Cleanup and Documentation

**Files:**
- Modify: `src/imessage_max/enrichment/__init__.py`

**Step 1: Add module docstring with usage**

```python
"""
Media enrichment pipeline for iMessage Max.

This module processes message attachments and links to provide rich context:

- Images (HEIC, JPEG, PNG, GIF): Converted to JPEG, resized to 1536px max, base64 encoded
- Videos (MOV, MP4): Thumbnail extracted at 3s, resized, includes duration
- Audio (CAF, M4A): Duration extracted for voice notes
- Links: Open Graph metadata (title, description, domain) fetched

Usage:
    from imessage_max.enrichment import process_image, process_video, process_audio, enrich_links

    # Process a single image
    result = process_image("/path/to/image.heic")
    # Returns: {"type": "image", "base64": "...", "filename": "image.heic"}

    # Enrich multiple links in parallel
    results = enrich_links(["https://example.com/a", "https://example.com/b"])
    # Returns: [{"url": "...", "domain": "...", "title": "...", "description": "..."}, ...]
"""

from .images import process_image
from .videos import process_video
from .audio import process_audio
from .links import enrich_link, enrich_links

__all__ = [
    "process_image",
    "process_video",
    "process_audio",
    "enrich_link",
    "enrich_links",
]
```

**Step 2: Run full test suite one more time**

Run: `pytest tests/ -v`
Expected: All tests PASS

**Step 3: Commit**

```bash
git add src/imessage_max/enrichment/__init__.py
git commit -m "docs(enrichment): Add module docstring with usage examples"
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Add dependencies | pyproject.toml |
| 2 | Image processor | enrichment/images.py |
| 3 | HEIC test | tests/test_enrichment_images.py |
| 4 | Video processor | enrichment/videos.py |
| 5 | Audio processor | enrichment/audio.py |
| 6 | Link enrichment | enrichment/links.py |
| 7 | Package exports | enrichment/__init__.py |
| 8 | Attachment query | queries.py |
| 9 | get_messages integration | tools/get_messages.py |
| 10 | Integration test | tests/integration/ |
| 11 | Documentation | enrichment/__init__.py |

**Total: ~11 tasks, ~33 commits**
