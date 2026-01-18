"""
Media enrichment pipeline for iMessage Max.

This module provides functions to process media attachments and links from iMessage
conversations, extracting useful metadata and generating AI-friendly representations.

Functions
---------
process_image(file_path)
    Convert images (HEIC, PNG, etc.) to base64-encoded JPEG, resized to max 1536px.
    Returns an ImageResult dict or None on failure.

process_video(file_path)
    Extract a thumbnail frame (~3 seconds in) and duration from video files.
    Returns a VideoResult dict or None on failure.

process_audio(file_path)
    Extract duration from audio files (CAF, M4A, etc.).
    Returns an AudioResult dict or None on failure.

enrich_link(url)
    Fetch Open Graph metadata (title, description) for a single URL.
    Always returns a LinkResult dict (with at least url and domain).

enrich_links(urls)
    Enrich multiple URLs in parallel using up to 4 worker threads.
    Returns results in the same order as input.

Usage Examples
--------------
Process an image attachment:

    >>> from imessage_max.enrichment import process_image
    >>> result = process_image("/path/to/photo.heic")
    >>> if result:
    ...     print(f"Got {result['type']}: {result['filename']}")
    ...     # result['base64'] contains the JPEG data
    Got image: photo.heic

Process a video to get thumbnail and duration:

    >>> from imessage_max.enrichment import process_video
    >>> result = process_video("/path/to/video.mov")
    >>> if result:
    ...     print(f"Video is {result['duration_seconds']}s long")
    ...     # result['thumbnail_base64'] contains the frame
    Video is 42s long

Get duration of a voice message:

    >>> from imessage_max.enrichment import process_audio
    >>> result = process_audio("/path/to/voice.caf")
    >>> if result:
    ...     print(f"Audio is {result['duration_seconds']}s")
    Audio is 15s

Enrich a single link:

    >>> from imessage_max.enrichment import enrich_link
    >>> result = enrich_link("https://example.com/article")
    >>> print(f"{result['domain']}: {result.get('title', 'No title')}")
    example.com: Example Article Title

Enrich multiple links in parallel:

    >>> from imessage_max.enrichment import enrich_links
    >>> urls = ["https://a.com", "https://b.com", "https://c.com"]
    >>> results = enrich_links(urls)
    >>> for r in results:
    ...     print(f"{r['domain']}: {r.get('title', 'No title')}")

Notes
-----
- All media processing functions return None on failure (file not found,
  unsupported format, corrupted data, etc.). Always check the return value.

- Images and video thumbnails are resized to fit within 1536x1536 pixels
  (MAX_DIMENSION) while preserving aspect ratio. Output is JPEG at 85% quality.

- Link enrichment has a 3-second timeout per request. On failure, a minimal
  result with just url and domain is returned (never None).

- enrich_links() processes up to 4 URLs concurrently (MAX_WORKERS=4) for
  better performance when handling multiple links.
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
