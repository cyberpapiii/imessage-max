# Media Enrichment for iMessage Max

**Date:** 2026-01-18
**Status:** Approved

## Goal

Enhance `get_messages` to return fully-enriched context - including viewable images/videos and link metadata - without follow-up tool calls.

## Problem

Currently, when Claude queries messages:
- **Images are opaque:** Claude sees metadata (filename, size) but can't view the actual content
- **Links lack context:** Claude sees raw URLs but not what they're about
- **Workarounds break philosophy:** Multiple follow-up calls to access attachments defeats the MCP's streamlined design

## Ideal Experience

A "catch me up on my texts" request gives Claude everything needed to say: "You sent Sukhmani a photo of naan bread shaped like bikinis, she said 'we don't need it?' but 'nice though'. Meanwhile in the group chat, Alex shared an Instagram reel about a doctor doing some sketchy procedure and Dylan was outraged about it."

## Architecture

```
get_messages()
    ↓
┌─────────────────────────────────────────────┐
│  Message Query (existing)                   │
└─────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────┐
│  Enrichment Pipeline (new)                  │
│  ├── images.py: HEIC→JPEG, resize to 1536px │
│  ├── videos.py: extract frame @3s, duration │
│  ├── audio.py: extract duration for voice   │
│  └── links.py: fetch OG title/description   │
└─────────────────────────────────────────────┘
    ↓
Enriched response with media[], links[], attachments[]
```

## Response Structure

```python
{
  "messages": [
    {
      "id": 12345,
      "text": "Check this out",
      "ts": "2025-01-18T14:30:00Z",
      "from": "alex",
      "media": [
        {"type": "image", "base64": "...", "filename": "IMG_1234.HEIC"},
        {"type": "video", "thumbnail_base64": "...", "duration_seconds": 30, "filename": "VID_5678.mov"}
      ],
      "links": [
        {"url": "https://instagram.com/reel/abc", "title": "Funny dog", "description": "Watch this...", "domain": "instagram.com"}
      ],
      "attachments": [
        {"filename": "contract.pdf", "size": 102400, "type": "pdf", "processed": false},
        {"filename": "Audio Message.caf", "size": 32382, "type": "audio", "duration_seconds": 15, "processed": false}
      ]
    }
  ],
  "media_truncated": false,
  "media_total": 3,
  "media_included": 3
}
```

### Field Semantics

- **`media[]`** - Processed images/videos with viewable content (base64 encoded)
- **`links[]`** - Unfurled URLs with Open Graph metadata
- **`attachments[]`** - Everything else: PDFs, audio, docs, or items that failed to process

An item appears in `media` OR `attachments`, never both. If all attachments process successfully, `attachments` is omitted.

## Processing Rules

| Input | Processing | Output Location |
|-------|------------|-----------------|
| HEIC/JPEG/PNG | Resize to 1536px max, base64 | `media[]` |
| GIF | First frame, resize, base64 | `media[]` |
| MOV/MP4 | Frame @3s, resize, base64 + duration | `media[]` |
| CAF/M4A (voice notes) | Extract duration only | `attachments[]` |
| URLs in text | Fetch OG tags (title, desc, domain) | `links[]` |
| PDF/docs | Metadata only | `attachments[]` |
| Failed processing | Metadata + `processed: false` | `attachments[]` |

### Image Processing Details

- **Resize:** 1536px on the long edge, maintain aspect ratio
- **Format:** Convert all to JPEG for consistency
- **Quality:** Sharp enough to read text in screenshots
- **Typical size:** 200-400KB per image after processing

### Video Processing Details

- **Frame extraction:** At 3 seconds (avoids black/loading first frames)
- **Thumbnail:** Same resize rules as images
- **Metadata:** Include `duration_seconds` and original `filename`
- **Output type:** Marked as `"type": "video"` so Claude knows it's a preview

### Link Processing Details

- **Source:** iMessage link preview cache when available, otherwise live fetch
- **Data:** Title, description, domain from Open Graph tags
- **No image fetch:** OG `image_url` not embedded (redundant - Claude can't see remote images anyway)
- **Graceful degradation:** Sparse OG data (common on Instagram) still returned - domain alone is useful context

### Voice Note Processing Details

- **Output location:** `attachments[]` (not `media[]` - no visual content to display)
- **Enrichment:** Extract duration via ffmpeg (same tooling as video)
- **Marker:** `processed: false` since Claude can't "hear" the audio
- **Value:** "Rob sent a 15-second voice note" is more useful than just "Rob sent a voice note"

Example output:
```python
{"type": "audio", "filename": "Audio Message.caf", "size": 32382, "duration_seconds": 15, "processed": false}
```

## Constraints

| Constraint | Value | Rationale |
|------------|-------|-----------|
| Max media | 10 | Prevent response bloat on image-heavy days |
| Image max dimension | 1536px | Readable for screenshots, reasonable file size |
| Link timeout | 2-3 seconds | Don't let slow sites block the response |
| Video frame position | 3 seconds | Avoid black/loading frames |

### When Media Cap is Hit

Prioritize by recency (most recent messages first). Response includes:
```python
{
  "media_truncated": true,
  "media_total": 23,
  "media_included": 10
}
```

## Error Handling

**Principle:** Never let enrichment failures break the core query.

### Graceful Degradation

- **Image/video fails:** Move to `attachments[]` with `processed: false`
- **Link unreachable:** Include with just `url` and `domain`
- **Overall timeout:** Return what's ready + `enrichment_partial: true`

No detailed error types exposed to Claude - the distinction between "file not found" vs "conversion failed" doesn't change the user-facing message. Keep detailed errors for internal logging.

## Performance

- **Parallelization:** Thread pool for image processing (4 concurrent) and link fetching
- **Lazy processing:** No background daemon, no pre-computation - process at query time
- **Typical latency:** 4-5 images in 24 hours = 10-15 seconds worst case on first query, acceptable for the use case

## Dependencies

### New Dependencies

| Package | Purpose | Notes |
|---------|---------|-------|
| `Pillow` | Image resize, JPEG conversion | Standard Python imaging |
| `pillow-heif` | HEIC support for Pillow | Required for iPhone photos |
| `imageio-ffmpeg` | Video frame extraction | Bundles ffmpeg binary (~80-100MB), no system dependency required |
| `beautifulsoup4` | Parse OG tags from HTML | Lightweight HTML parsing |

### Existing Dependencies

- `httpx` - Already in deps, used for link metadata fetching

### Install Path Compatibility

`imageio-ffmpeg` bundles its own ffmpeg binary, so it works automatically across all install methods:
- Desktop Extension (.mcpb)
- `pip install`
- `uv pip install`
- From source

No user action required - ffmpeg is an implementation detail.

## Module Structure

```
src/imessage_max/
├── enrichment/
│   ├── __init__.py
│   ├── images.py      # HEIC conversion, resize, base64 encoding
│   ├── videos.py      # ffmpeg frame extraction, duration
│   ├── audio.py       # ffmpeg duration extraction for voice notes
│   └── links.py       # OG metadata fetching
├── tools/
│   └── get_messages.py  # Updated to call enrichment pipeline
```

## Design Decisions

### Why not pre-compute descriptions?

The "catch me up" use case is inherently recent (last 24-48 hours). Pre-computing descriptions for entire message history is overkill. Lazy processing at query time is simpler and sufficient.

### Why return base64 instead of descriptions?

Claude has built-in vision capabilities. Returning the actual image data lets Claude see and understand the content directly, rather than relying on a separate vision API to generate descriptions. The MCP's job is data access, not data interpretation.

### Why always include enrichment (no toggle)?

The philosophy is "give Claude full context." There's no clear use case for wanting messages without enrichment. Toggles can be added later if a real performance problem emerges.

### Why keep `attachments[]` as fallback?

Not everything can be processed: PDFs, audio, documents, corrupted files. Keeping a fallback array ensures Claude still knows these items exist, even if it can't see inside them.
