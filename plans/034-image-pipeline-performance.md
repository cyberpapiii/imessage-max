# Plan 034: Image pipeline performance — stop rebuilding CIContext, downsample via ImageIO, cap full-variant output

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift swift/Sources/iMessageMax/Tools/GetMessages.swift swift/Sources/iMessageMax/Tools/GetAttachment.swift`
> Plan 022 rewrites `GetMessages.swift:330-331` (path validation) — that
> drift is expected; work with its version. Any structural change to
> `ImageProcessor.swift` itself is a STOP condition.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW-MED (output bytes change for downsampled variants; dimensions
  must not)
- **Depends on**: 022 (rewrites the same GetMessages lines; land 022 first
  so this plan edits its validated-path version). Do NOT land concurrently
  with 022.
- **Category**: performance
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

Three separate inefficiencies in one small pipeline:

1. **A fresh `CIContext` per message-list attachment.** `ImageProcessor.init`
   builds a `CIContext` (GPU pipeline setup — one of the most expensive
   objects in Core Image; Apple's docs say to create one and reuse it).
   `GetMessages` constructs a new `ImageProcessor()` *inside the per-
   attachment loop*, so listing 50 messages with 20 images builds 20 GPU
   contexts — and then never uses any of them, because `getMetadata` only
   touches `CGImageSource`, not the context.
2. **Full-image decode to produce a thumbnail.** `process(at:variant:)`
   decodes the entire image via `CIImage(contentsOf:)`, scales, and
   re-encodes. For a 12MP HEIC → 400px thumb, that's a ~48MB decode to
   produce a ~20KB output. `CGImageSourceCreateThumbnailAtIndex` does the
   same job with a fraction of the memory and time, and it honors EXIF
   orientation.
3. **The `full` variant is unbounded.** `ImageVariant.full` re-encodes the
   original at full resolution and returns it inline as base64 MCP content —
   a 40MB photo becomes a ~53MB JSON payload to the client. There is no cap.

## Current state

`swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift` (107 lines, the
whole live surface):

```swift
struct ImageProcessor {
    private let context: CIContext

    init() {
        self.context = CIContext(options: [
            .useSoftwareRenderer: false,
            .highQualityDownsample: true
        ])
    }

    /// Get metadata without full processing (fast path)
    func getMetadata(at path: String) -> ImageMetadata? {
        // CGImageSourceCreateWithURL + CGImageSourceCopyPropertiesAtIndex
        // + FileManager attributes — the CIContext is NOT used here.
    }

    /// Process image to JPEG at specified variant
    func process(at path: String, variant: ImageVariant) -> ImageResult? {
        // CIImage(contentsOf:) full decode
        // scale via CGAffineTransform if variant.maxDimension caps it
        // context.jpegRepresentation(of:colorSpace:options: [:])
    }
}
```

Variants (`:8-19`): `vision` → 1568px, `thumb` → 400px, `full` → nil
(no cap).

Call sites:
- `swift/Sources/iMessageMax/Tools/GetAttachment.swift:24` —
  `init(db: Database = Database(), imageProcessor: ImageProcessor = ImageProcessor())`
  (one instance per tool actor — fine). Returns image content at `:74-75`
  via `.plainText(metadata) + .plainImage(data:mimeType:)`.
- `swift/Sources/iMessageMax/Tools/GetMessages.swift:328-345` — the media
  loop. As of `e3d14da` (plan 022 replaces the two marked lines with
  `AttachmentPathPolicy` validation; keep its version and only fix the
  processor construction):

```swift
                    if attType == "image" && mediaCount < maxMedia,
                       let path = att.filename {
                        let expandedPath = (path as NSString).expandingTildeInPath   // ← 022 rewrites
                        let processor = ImageProcessor()                             // ← the per-iteration build
                        if let metadata = processor.getMetadata(at: expandedPath) {
```

Existing tests: `GetAttachmentToolTests` (in `PlaceholderTests.swift:304-373`
at `e3d14da`; its own file after plan 032) uses `makeTestImage(width: 2000,
height: 1000, ...)` + `makeAttachmentTestDatabase` and asserts on resized
output — these are the characterization net for `process` changes.
`GetMessagesToolTests.swift` covers the media loop.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Attachment tests | `cd swift && swift test --filter GetAttachmentToolTests` | all pass |
| Messages tests | `cd swift && swift test --filter GetMessagesToolTests` | all pass |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift`
- `swift/Sources/iMessageMax/Tools/GetMessages.swift` (the one construction
  line only)
- The test file holding `GetAttachmentToolTests` (add tests)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `GetAttachment.swift` tool logic and its response shapes — the byte cap
  lives inside `ImageProcessor.process`, not in the tool.
- Path validation (`AttachmentPathPolicy`) — plan 022's territory.
- The MCP content encoding (`.plainImage`) — plan-030/ServerExtensions land.
- Video/audio processors — deleted by plan 032; do not resurrect.

## Git workflow

- Branch: `advisor/034-image-pipeline-performance`
- Conventional commits, e.g. `perf: share CIContext, thumbnail via ImageIO, cap full-variant bytes`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Share the CIContext; stop per-iteration construction

In `ImageProcessor.swift`, make the context a shared static (CIContext is
thread-safe per Apple's documentation):

```swift
struct ImageProcessor {
    // CIContext is expensive to build and thread-safe to share; one per
    // process, not one per call site.
    private static let sharedContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .highQualityDownsample: true
    ])
    private var context: CIContext { Self.sharedContext }

    init() {}
```

(Keeping `init()` and the instance API means `GetAttachment.swift:24` and
all call sites compile unchanged.)

In `GetMessages.swift`, hoist the now-cheap-but-still-pointless construction
out of the loop: declare `let processor = ImageProcessor()` once above the
`for att in rowAttachments` loop (or at the top of `executeImpl`) and reuse
it. Do not restructure anything else in the loop.

**Verify**: `cd swift && swift build` → exit 0; `swift test` → green.

### Step 2: Downsample via ImageIO for capped variants

Rewrite `process(at:variant:)` so variants with a `maxDimension` use
`CGImageSourceCreateThumbnailAtIndex`, and only `full` takes the CIImage
path:

```swift
    func process(at path: String, variant: ImageVariant) -> ImageResult? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        if let maxDim = variant.maxDimension {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,   // honors EXIF orientation
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDim,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let ciImage = CIImage(cgImage: cgImage)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let jpegData = context.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [:])
            else { return nil }
            return ImageResult(data: jpegData, format: "jpeg", width: cgImage.width, height: cgImage.height)
        }

        // full variant: existing CIImage path, unchanged — plus Step 3's cap
        ...
    }
```

Behavior contract to preserve (this is what the existing tests check):
- Output is JPEG.
- Neither output dimension exceeds `maxDimension`.
- Images already smaller than `maxDimension` are not upscaled
  (`kCGImageSourceThumbnailMaxPixelSize` never upscales — same behavior as
  the old `min(scale, 1.0)`).

One intentional change: EXIF-rotated photos now come out orientation-
corrected (the `WithTransform` option). The old CIImage path did not apply
orientation. This is a fix, not a regression — note it in the commit message.

**Verify**: `swift test --filter GetAttachmentToolTests` → all pass
(dimension assertions hold). Then full suite.

### Step 3: Cap the full variant

Add a byte guard to the `full` branch: after producing `jpegData`, if
`jpegData.count` exceeds a limit, re-run the capped path instead:

```swift
    /// Ceiling for inline "full" output. MCP content is base64ed into JSON;
    /// beyond this the payload stops being useful to any client. Oversized
    /// originals fall back to the vision-sized render.
    private static let maxFullVariantBytes = 8 * 1024 * 1024
```

In the `full` branch: if the rendered JPEG is larger than
`maxFullVariantBytes`, return `process(at: path, variant: .vision)` instead
(one recursion level, and `.vision` never recurses — it takes the capped
branch). The `ImageResult` then reports the vision dimensions, which keeps
width/height honest.

**Verify**: build + full suite green.

### Step 4: Tests

Add to `GetAttachmentToolTests` (reusing its `makeTestImage` helper):

1. `testThumbVariantHonorsMaxDimensionAndDoesNotUpscale` — 2000x1000 source,
   `.thumb` → max side 400; then a 100x50 source → output stays 100x50.
2. `testFullVariantOversizeFallsBackToVisionSize` — only if `makeTestImage`
   can cheaply produce a >8MB JPEG (e.g. large dimensions + noise). If it
   can't within ~15 lines of helper change, instead make
   `maxFullVariantBytes` an internal `static var` is NOT allowed — keep it
   `let`; write the test by generating a big random-pixel image, and if
   that's still under 8MB, skip this test and note it in the commit message.
   Do not weaken the constant for testability.
3. `testProcessedOutputIsJPEG` — assert the returned `format == "jpeg"` and
   the data starts with the JPEG magic bytes `0xFF 0xD8`.

**Verify**: `cd swift && swift test` → exit 0, 0 failures, ≥2 net-new tests.

## Test plan

Step 4, plus the existing `GetAttachmentToolTests` acting as the
characterization net through Step 2's rewrite.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures; ≥2 net-new tests
- [ ] `grep -c "CIContext(" swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift` → 1 (the static)
- [ ] `grep -n "ImageProcessor()" swift/Sources/iMessageMax/Tools/GetMessages.swift` → 0 or 1 match, and NOT inside the `for att in rowAttachments` loop
- [ ] `grep -n "CGImageSourceCreateThumbnailAtIndex" swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift` → present
- [ ] `grep -n "maxFullVariantBytes" swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift` → present
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 022 has not landed and `GetMessages.swift:330` still has the raw
  `expandingTildeInPath` — land order matters (022 first); report.
- Existing attachment tests fail on *dimensions* after Step 2 — the
  ImageIO thumbnail rounds differently than the CIImage scale did; report
  the exact before/after dimensions rather than loosening assertions
  yourself.
- `jpegRepresentation` from a `CIImage(cgImage:)` misbehaves (nil output) on
  some format — report the format; do not silently fall back to the full
  decode path.

## Maintenance notes

- The shared `CIContext` is process-global; if a future change needs
  different context options per variant, split into named static contexts —
  never go back to per-call construction.
- The 8MB full-variant cap is a product decision encoded as a constant; if a
  client legitimately needs bigger originals, the right mechanism is a file
  handoff (path-based), not a bigger inline payload.
- Plan 022 (GetMessages path containment) and this plan touch adjacent
  lines; whichever lands second must re-read the loop.
