// Sources/iMessageMax/Enrichment/ImageProcessor.swift
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageVariant: String, CaseIterable {
    case vision = "vision"  // 1568px - AI analysis
    case thumb = "thumb"    // 400px - quick preview
    case full = "full"      // original resolution

    var maxDimension: Int? {
        switch self {
        case .vision: return 1568
        case .thumb: return 400
        case .full: return nil
        }
    }
}

struct ImageResult {
    let data: Data
    let format: String
    let width: Int
    let height: Int
}

struct ImageMetadata {
    let filename: String
    let sizeBytes: Int
    let width: Int
    let height: Int
}

struct ImageProcessor {
    // CIContext is expensive to build and thread-safe to share; one per
    // process, not one per call site.
    private static let sharedContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .highQualityDownsample: true
    ])
    private var context: CIContext { Self.sharedContext }

    /// Ceiling for inline "full" output. MCP content is base64ed into JSON;
    /// beyond this the payload stops being useful to any client. Oversized
    /// originals fall back to the vision-sized render.
    private static let maxFullVariantBytes = 8 * 1024 * 1024

    init() {}

    /// Get metadata without full processing (fast path)
    func getMetadata(at path: String) -> ImageMetadata? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int
        else { return nil }

        return ImageMetadata(
            filename: url.lastPathComponent,
            sizeBytes: size,
            width: width,
            height: height
        )
    }

    /// Process image to JPEG at specified variant
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

        // full variant: original CIImage decode path (unbounded dimensions).
        guard let ciImage = CIImage(contentsOf: url) else { return nil }

        let originalSize = ciImage.extent.size

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpegData = context.jpegRepresentation(
                  of: ciImage,
                  colorSpace: colorSpace,
                  options: [:]
              )
        else { return nil }

        // Oversized originals fall back to the vision-sized render (which never recurses).
        if jpegData.count > Self.maxFullVariantBytes {
            return process(at: path, variant: .vision)
        }

        return ImageResult(
            data: jpegData,
            format: "jpeg",
            width: Int(originalSize.width),
            height: Int(originalSize.height)
        )
    }
}
