import AppKit

// The app icon is a satin-silver speech bubble on a blue tile, catching a lens
// flare at its shoulder. The build script prepends the MaxBrand sources to this
// renderer, so the bubble has the same outline as the panel and the menu bar.
// The metal is shaded pixel by pixel, so the build compiles this file with
// optimisation instead of interpreting it.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let space = CGColorSpaceCreateDeviceRGB()
typealias RGB = (Double, Double, Double)

func colour(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(colorSpace: space, components: [red, green, blue, alpha])!
}
func gradient(_ colours: [CGColor], _ locations: [CGFloat]) -> CGGradient {
  CGGradient(colorsSpace: space, colors: colours as CFArray, locations: locations)!
}
func smooth(_ from: Double, _ to: Double, _ x: Double) -> Double {
  let t = min(max((x - from) / (to - from), 0), 1)
  return t * t * (3 - 2 * t)
}
func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
  (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}
func bump(_ centre: Double, _ width: Double, _ x: Double) -> Double {
  let t = (x - centre) / width
  return exp(-t * t)
}

// Everything is drawn on a 1024 canvas with a top-left origin. The tile sits on
// the standard macOS icon grid, 824 points inside 1024, leaving room for its
// own shadow.
let tile = CGPath(
  roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186,
  cornerHeight: 186, transform: nil)
let face = CGRect(x: 200, y: 206, width: 624, height: 624)
let bubble = MessageMark.body(in: face)
let tileColours = [colour(0.36, 0.76, 1), colour(0.13, 0.50, 0.97), colour(0.03, 0.30, 0.86)]
let glowTint: (CGFloat, CGFloat, CGFloat) = (0.90, 0.96, 1.0)

// MARK: - The metal

/// The bubble is shaded on a grid finer than the canvas, then drawn down.
let grid = 1440
let inside: [Bool] = (0..<grid * grid).map { k in
  let x = face.minX + (CGFloat(k % grid) + 0.5) / CGFloat(grid) * face.width
  let y = face.minY + (CGFloat(k / grid) + 0.5) / CGFloat(grid) * face.height
  return bubble.contains(CGPoint(x: x, y: y))
}

func blur(_ values: [Double], _ radius: Int) -> [Double] {
  var source = values
  var result = values
  for pass in 0..<4 {
    let horizontal = pass % 2 == 0
    for j in 0..<grid {
      for i in 0..<grid {
        var sum = 0.0
        for k in -radius...radius {
          let n = min(max((horizontal ? i : j) + k, 0), grid - 1)
          sum += horizontal ? source[j * grid + n] : source[n * grid + i]
        }
        result[j * grid + i] = sum / Double(2 * radius + 1)
      }
    }
    source = result
  }
  return result
}

/// Surface normals of the bubble inflated like a balloon (a Poisson solve), so
/// the metal has no crease where the tail joins the body.
let normals: (x: [Double], y: [Double], z: [Double]) = {
  let coarse = 360
  let step = grid / coarse
  var height = [Double](repeating: 0, count: coarse * coarse)
  let mask = (0..<coarse * coarse).map { k in
    inside[((k / coarse) * step + step / 2) * grid + (k % coarse) * step + step / 2]
  }
  for _ in 0..<3000 {
    for j in 1..<(coarse - 1) {
      for i in 1..<(coarse - 1) where mask[j * coarse + i] {
        let k = j * coarse + i
        let sum = height[k - 1] + height[k + 1] + height[k - coarse] + height[k + coarse] + 1
        height[k] += 1.97 * (sum / 4 - height[k])
      }
    }
  }
  let top = height.max()!
  var fine = [Double](repeating: 0, count: grid * grid)
  let limit = Double(coarse) - 1.001
  for j in 0..<grid {
    for i in 0..<grid {
      let x = min(max((Double(i) + 0.5) / Double(step) - 0.5, 0), limit)
      let y = min(max((Double(j) + 0.5) / Double(step) - 0.5, 0), limit)
      let (xi, yi) = (Int(x), Int(y))
      let (fx, fy) = (x - Double(xi), y - Double(yi))
      let o = yi * coarse + xi
      let upper = height[o] * (1 - fx) + height[o + 1] * fx
      let lower = height[o + coarse] * (1 - fx) + height[o + coarse + 1] * fx
      fine[j * grid + i] = sqrt(max(upper * (1 - fy) + lower * fy, 0) / top)
    }
  }
  fine = blur(blur(blur(fine, 14), 14), 10)
  var nx = fine
  var ny = fine
  var nz = fine
  let steepness = 460.0
  for j in 0..<grid {
    for i in 0..<grid {
      let k = j * grid + i
      let gx = (fine[j * grid + min(i + 1, grid - 1)] - fine[j * grid + max(i - 1, 0)]) * 0.5 * steepness
      let gy = (fine[min(j + 1, grid - 1) * grid + i] - fine[max(j - 1, 0) * grid + i]) * 0.5 * steepness
      let length = sqrt(gx * gx + gy * gy + 1)
      nx[k] = -gx / length
      ny[k] = -gy / length
      nz[k] = 1 / length
    }
  }
  return (nx, ny, nz)
}()

/// The body without its tail, as a circle in the grid's 0...1 space: the
/// widest row gives the centre, the average of width and height the radius.
/// The reflection is taken from this ball, so the tail never bends it.
let ball: (x: Double, y: Double, radius: Double) = {
  var widest = (span: 0, from: 0, to: 0)
  for j in 0..<grid {
    let row = (0..<grid).filter { inside[j * grid + $0] }
    if let first = row.first, let last = row.last, last - first > widest.span {
      widest = (last - first, first, last)
    }
  }
  let centre = (widest.from + widest.to) / 2
  let column = (0..<grid).filter { inside[$0 * grid + centre] }
  let (top, bottom) = (column.first ?? 0, column.last ?? 0)
  let n = Double(grid)
  return (
    Double(centre) / n, Double(top + bottom) / 2 / n,
    (Double(widest.span) / 2 + Double(bottom - top) / 2) / 2 / n
  )
}()

/// Satin silver: a soft dark horizon curving round the ball, turned 10 degrees
/// toward the flare, with faint iridescent fringes at its edges and the blue
/// tile bouncing back into the underside.
func silver(_ k: Int, _ u: Double, _ v: Double) -> RGB {
  let (x, y, z) = (normals.x[k], normals.y[k], normals.z[k])
  let turn = 10.0 * .pi / 180
  let arc = 1.0
  let px = (u - ball.x) / ball.radius - sin(turn) * arc
  let py = (v - ball.y) / ball.radius + cos(turn) * arc
  let up = 1.9 * (arc + 0.14 - sqrt(px * px + py * py))

  let dark: RGB = (0.44, 0.46, 0.49)
  let haze: RGB = (0.72, 0.74, 0.77)
  let pale: RGB = (0.80, 0.83, 0.85)
  let horizon = smooth(-0.30, 0.28, up)
  let rimward = pow(1 - z, 1.6)
  let sky = mix(haze, (0.95, 0.96, 0.97), smooth(0, 0.9, up))
  let ground = mix(dark, pale, pow(smooth(0, -1.15, up), 0.8))
  var shade = mix(ground, sky, horizon)
  shade = mix(shade, mix(haze, pale, 0.5), min(rimward * 0.7, 1) * (1 - horizon))
  shade = mix(shade, (0.56, 0.76, 1.0), min(smooth(-0.7, -1.7, up) * 0.40 + rimward * 0.18, 1))

  let strength = 0.25
  shade = mix(shade, (1.0, 0.60, 0.16), bump(0.10, 0.075, up) * strength)
  shade = mix(shade, (0.92, 0.26, 0.40), bump(0, 0.05, up) * strength * 0.6)
  shade = mix(shade, (0.40, 0.84, 1.0), bump(-0.80, 0.10, up) * strength * 0.8)
  shade = mix(shade, (0.66, 0.50, 1.0), bump(-1.0, 0.08, up) * strength * 0.45)

  let facing = max(0, x * 0.42 + y * -0.58 + z * 0.70)
  let light = pow(facing, 110) * 1.1 + pow(facing, 14) * 0.10 + pow(1 - z, 2.6) * 0.55
  return (shade.0 + light, shade.1 + light, shade.2 + light)
}

// MARK: - Drawing

func drawTile(_ context: CGContext) {
  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: colour(0, 0, 0, 0.32))
  context.setFillColor(tileColours[1])
  context.addPath(tile)
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  context.addPath(tile)
  context.clip()
  context.drawLinearGradient(
    gradient(tileColours, [0, 0.5, 1]), start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924),
    options: [])
  let top = CGPoint(x: 512, y: 40)
  context.drawRadialGradient(
    gradient([colour(1, 1, 1, 0.25), colour(1, 1, 1, 0)], [0, 1]), startCenter: top,
    startRadius: 0, endCenter: top, endRadius: 640, options: [])
  context.addPath(tile)
  context.setLineWidth(10)
  context.replacePathWithStrokedPath()
  context.clip()
  context.drawLinearGradient(
    gradient([colour(1, 1, 1, 0.5), colour(1, 1, 1, 0.04), colour(0, 0, 0, 0.25)], [0, 0.45, 1]),
    start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
  context.restoreGState()
}

func drawBubble(_ context: CGContext) {
  // A soft glow around the bubble, then a shadow lifting it off the tile.
  for (radius, alpha) in [(90, 0.40), (30, 0.45)] as [(CGFloat, CGFloat)] {
    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.setShadow(
      offset: .zero, blur: radius, color: colour(glowTint.0, glowTint.1, glowTint.2, alpha))
    context.addPath(bubble)
    context.setFillColor(colour(1, 1, 1))
    context.fillPath()
    context.restoreGState()
  }
  context.saveGState()
  context.setShadow(
    offset: CGSize(width: 0, height: -16), blur: 30, color: colour(0, 0.14, 0.42, 0.40))
  context.addPath(bubble)
  context.setFillColor(colour(1, 1, 1))
  context.fillPath()
  context.restoreGState()

  var pixels = [UInt8](repeating: 0, count: grid * grid * 4)
  for k in 0..<grid * grid where inside[k] {
    let tone = silver(k, Double(k % grid) / Double(grid), Double(k / grid) / Double(grid))
    pixels[k * 4] = UInt8(min(max(tone.0, 0), 1) * 255)
    pixels[k * 4 + 1] = UInt8(min(max(tone.1, 0), 1) * 255)
    pixels[k * 4 + 2] = UInt8(min(max(tone.2, 0), 1) * 255)
    pixels[k * 4 + 3] = 255
  }
  let image = CGImage(
    width: grid, height: grid, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: grid * 4,
    space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: true,
    intent: .defaultIntent)!
  context.saveGState()
  context.addPath(bubble)
  context.clip()
  context.interpolationQuality = .high
  context.translateBy(x: 0, y: face.minY + face.maxY)
  context.scaleBy(x: 1, y: -1)
  context.draw(image, in: face)
  context.restoreGState()

  // A thin bright rim, brightest along the top edge.
  context.saveGState()
  context.addPath(bubble)
  context.setLineWidth(8)
  context.replacePathWithStrokedPath()
  context.clip()
  context.drawLinearGradient(
    gradient([colour(1, 1, 1, 1), colour(1, 1, 1, 0.6)], [0, 1]),
    start: CGPoint(x: 0, y: face.minY), end: CGPoint(x: 0, y: face.maxY), options: [])
  context.restoreGState()
}

/// A lens flare at the bubble's shoulder: a hot core in a wide bloom, long thin
/// streaks on the diagonals, and a four-point sparkle whose rays swell into the
/// core along concave curves.
func drawFlare(_ context: CGContext, at centre: CGPoint) {
  func glow(_ stops: [(CGFloat, CGFloat)], _ tint: (CGFloat, CGFloat, CGFloat) = (1, 1, 1))
    -> CGGradient
  {
    gradient(stops.map { colour(tint.0, tint.1, tint.2, $0.1) }, stops.map { $0.0 })
  }
  func streak(
    _ length: CGFloat, _ thickness: CGFloat, _ degrees: CGFloat, _ alpha: CGFloat,
    inward: CGFloat = 1
  ) {
    // The arm pointing into the bubble is shorter, so it does not scratch the metal.
    for side in [CGFloat(1), -1] {
      let reach = side > 0 ? length : length * inward
      context.saveGState()
      context.translateBy(x: centre.x, y: centre.y)
      context.rotate(by: degrees * .pi / 180)
      context.clip(
        to: CGRect(x: side > 0 ? 0 : -reach, y: -thickness, width: reach, height: thickness * 2))
      context.scaleBy(x: reach, y: thickness)
      context.drawRadialGradient(
        glow([(0, alpha), (0.20, alpha * 0.85), (0.55, alpha * 0.30), (1, 0)]),
        startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
      context.restoreGState()
    }
  }
  context.saveGState()
  context.addPath(tile)
  context.clip()
  context.setBlendMode(.plusLighter)
  context.drawRadialGradient(
    glow([(0, 0.62), (0.25, 0.30), (0.6, 0.09), (1, 0)], (glowTint.0 - 0.01, glowTint.1, glowTint.2 - 0.02)),
    startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 270, options: [])
  context.drawRadialGradient(
    glow([(0, 0.9), (0.4, 0.35), (1, 0)]), startCenter: centre, startRadius: 0,
    endCenter: centre, endRadius: 92, options: [])
  for (thickness, alpha) in [(44, 0.16), (24, 0.34), (8.5, 1.0)] as [(CGFloat, CGFloat)] {
    streak(400, thickness, -45, alpha, inward: 0.45)
  }
  streak(330, 3.2, -45, 0.8, inward: 0.45)
  for (thickness, alpha) in [(36, 0.14), (19, 0.30), (7, 1.0)] as [(CGFloat, CGFloat)] {
    streak(260, thickness, 45, alpha)
  }
  streak(210, 2.8, 45, 0.8)
  for degrees in [CGFloat(0), 90] {
    streak(120, 10, degrees, 0.22)
    streak(120, 4, degrees, 0.8)
  }
  for (scale, power, alpha) in [(1.0, 5.2, 0.42), (0.60, 3.8, 0.60)] as [(CGFloat, Double, CGFloat)] {
    let sparkle = CGMutablePath()
    for step in 0..<400 {
      let angle = Double(step) / 400 * 2 * .pi
      let (cosine, sine) = (cos(angle), sin(angle))
      let reach = (cosine >= 0 ? 330 : 160) * scale
      let point = CGPoint(
        x: reach * CGFloat((cosine < 0 ? -1 : 1) * pow(abs(cosine), power)),
        y: 215 * scale * CGFloat((sine < 0 ? -1 : 1) * pow(abs(sine), power)))
      if step == 0 { sparkle.move(to: point) } else { sparkle.addLine(to: point) }
    }
    sparkle.closeSubpath()
    context.saveGState()
    context.translateBy(x: centre.x, y: centre.y)
    context.rotate(by: -45 * .pi / 180)
    context.addPath(sparkle)
    context.clip()
    context.drawRadialGradient(
      glow([(0, alpha), (0.30, alpha * 0.7), (0.70, alpha * 0.22), (1, 0)]), startCenter: .zero,
      startRadius: 0, endCenter: .zero, endRadius: 330 * scale, options: [])
    context.restoreGState()
  }
  context.drawRadialGradient(
    glow([(0, 1), (0.5, 1), (1, 0)]), startCenter: centre, startRadius: 0, endCenter: centre,
    endRadius: 20, options: [])
  context.restoreGState()
}

// MARK: - Output

func bitmap(_ pixels: Int) -> NSBitmapImageRep {
  NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
}

// The icon is drawn once at full size; every smaller size is scaled from it.
let master = bitmap(1024)
let canvas = NSGraphicsContext(bitmapImageRep: master)!.cgContext
canvas.translateBy(x: 0, y: 1024)
canvas.scaleBy(x: 1, y: -1)
drawTile(canvas)
drawBubble(canvas)
drawFlare(canvas, at: CGPoint(x: 690, y: 320))
let full = master.cgImage!

for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let image = bitmap(pixels)
    let context = NSGraphicsContext(bitmapImageRep: image)!.cgContext
    context.interpolationQuality = .high
    context.draw(full, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let suffix = scale == 2 ? "@2x" : ""
    let png = image.representation(using: .png, properties: [:])!
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
