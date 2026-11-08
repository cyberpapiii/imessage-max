import AppKit
import MaxBrand

@MainActor
enum MenuBarArtwork {
  private static var cache: [CompanionMood: NSImage] = [:]
  static let points: CGFloat = 20

  static func image(for mood: CompanionMood) -> NSImage {
    if let image = cache[mood] { return image }
    let image = NSImage(size: NSSize(width: points, height: points))
    for scale in [1, 2] {
      let pixels = Int(points) * scale
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
      bitmap.size = NSSize(width: points, height: points)
      let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
      // bitmap.size already sets the representation's backing scale.
      context.translateBy(x: 0, y: points)
      context.scaleBy(x: 1, y: -1)
      draw(mood, in: context)
      image.addRepresentation(bitmap)
    }
    image.isTemplate = true
    cache[mood] = image
    return image
  }

  private static func draw(_ mood: CompanionMood, in context: CGContext) {
    let pose = mood.menuBarPose
    let rect = CGRect(x: 0, y: 0, width: points, height: points)
    let marks = MaxFace.eyes(pose, in: rect)
    context.setFillColor(NSColor.black.cgColor)
    if mood.menuBarOutlined {
      context.addPath(
        MessageMark.rounded(
          MaxFace.silhouette(pose, in: rect.insetBy(dx: 0.75, dy: 0.75)), width: 1.5))
      context.addPath(marks)
    } else {
      context.addPath(MaxFace.silhouette(pose, in: rect).subtracting(marks))
    }
    if let badge = MaxFace.badge(pose, in: rect) { context.addPath(badge) }
    context.fillPath()
  }
}
