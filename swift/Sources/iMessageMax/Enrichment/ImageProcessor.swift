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
    private let context: CIContext

    init() {
        self.context = CIContext(options: [
            .useSoftwareRenderer: false,
            .highQualityDownsample: true
        ])
    }

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

        guard let ciImage = CIImage(contentsOf: url) else { return nil }

        var image = ciImage
        let originalSize = ciImage.extent.size

        // Resize if needed
        if let maxDim = variant.maxDimension {
            let scale = min(
                CGFloat(maxDim) / originalSize.width,
                CGFloat(maxDim) / originalSize.height,
                1.0
            )

            if scale < 1.0 {
                image = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }

        // Render to JPEG
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpegData = context.jpegRepresentation(
                  of: image,
                  colorSpace: colorSpace,
                  options: [:]
              )
        else { return nil }

        let finalSize = image.extent.size
        return ImageResult(
            data: jpegData,
            format: "jpeg",
            width: Int(finalSize.width),
            height: Int(finalSize.height)
        )
    }
}
