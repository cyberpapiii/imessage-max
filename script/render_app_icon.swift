import AppKit

// The app icon is the panel's bubble at rest, upright, as a white bubble on a
// blue tile. The build script prepends the MaxBrand sources to this renderer, so
// the icon, the menu bar, and the panel share one drawing.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let space = CGColorSpaceCreateDeviceRGB()
func colour(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(colorSpace: space, components: [red, green, blue, alpha])!
}
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    // A top-left origin on a 1024 canvas matches the face's own grid.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
    func gradient(_ colours: [CGColor], _ locations: [CGFloat]) -> CGGradient {
      CGGradient(colorsSpace: space, colors: colours as CFArray, locations: locations)!
    }
    // The tile sits on the standard macOS icon grid: 824 points inside 1024,
    // leaving room for its own shadow.
    let frame = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = CGPath(roundedRect: frame, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: colour(0, 0, 0, 0.30))
    context.setFillColor(colour(0.10, 0.42, 0.93))
    context.addPath(tile)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(
      gradient([colour(0.36, 0.76, 1.0), colour(0.13, 0.50, 0.97), colour(0.03, 0.30, 0.86)], [0, 0.5, 1]),
      start: CGPoint(x: 0, y: frame.minY), end: CGPoint(x: 0, y: frame.maxY), options: [])
    // Light pooling at the top of the tile and a thin bright rim give it a
    // surface rather than a flat fill.
    context.drawRadialGradient(
      gradient([colour(1, 1, 1, 0.30), colour(1, 1, 1, 0)], [0, 1]),
      startCenter: CGPoint(x: 512, y: frame.minY - 60), startRadius: 0,
      endCenter: CGPoint(x: 512, y: frame.minY - 60), endRadius: 640, options: [])
    context.addPath(tile)
    context.setLineWidth(10)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(
      gradient([colour(1, 1, 1, 0.55), colour(1, 1, 1, 0.05), colour(0, 0, 0.2, 0.18)], [0, 0.45, 1]),
      start: CGPoint(x: 0, y: frame.minY), end: CGPoint(x: 0, y: frame.maxY), options: [])
    context.restoreGState()

    var pose = MaxPose.rest
    pose[.lean] = 0
    let face = CGRect(x: 200, y: 206, width: 624, height: 624)
    let body = MaxFace.silhouette(pose, in: face)
    let mark = MaxFace.sparkle(pose, in: face)

    // The bubble: white, lit from above, lifted off the tile by its shadow.
    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.setShadow(
      offset: CGSize(width: 0, height: -22), blur: 44, color: colour(0.0, 0.14, 0.45, 0.45))
    context.setFillColor(colour(1, 1, 1))
    context.addPath(body)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(body)
    context.clip()
    context.drawLinearGradient(
      gradient([colour(1, 1, 1), colour(0.97, 0.98, 1.0), colour(0.80, 0.87, 0.97)], [0, 0.55, 1]),
      start: CGPoint(x: 0, y: face.minY + 60), end: CGPoint(x: 0, y: face.maxY - 50), options: [])
    context.restoreGState()

    // The sparkle is pressed into the bubble: the tile's blue, darker at its
    // upper edge where the bubble would shade it.
    context.saveGState()
    context.addPath(mark)
    context.clip()
    context.drawLinearGradient(
      gradient([colour(0.05, 0.33, 0.88), colour(0.16, 0.55, 0.99), colour(0.36, 0.74, 1.0)], [0, 0.55, 1]),
      start: CGPoint(x: 0, y: face.minY + 150), end: CGPoint(x: 0, y: face.minY + 430), options: [])
    context.restoreGState()

    let suffix = scale == 2 ? "@2x" : ""
    let png = bitmap.representation(using: .png, properties: [:])!
    try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    if pixels == 1024 { try png.write(to: output.appendingPathComponent("AppIcon-preview.png")) }
  }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
try FileManager.default.removeItem(at: iconset)
