import AppKit
let out = CommandLine.arguments[1]
let space = CGColorSpaceCreateDeviceRGB()
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
func grad(_ cs: [CGColor], _ l: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: space, colors: cs as CFArray, locations: l)! }
let frame = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = CGPath(roundedRect: frame, cornerWidth: 186, cornerHeight: 186, transform: nil)
func drawTile(_ g: CGContext, _ cols: [CGColor], glow: CGFloat = 0.30) {
  g.saveGState(); g.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: c(0, 0, 0, 0.32))
  g.setFillColor(cols[1]); g.addPath(tile); g.fillPath(); g.restoreGState()
  g.saveGState(); g.addPath(tile); g.clip()
  g.drawLinearGradient(grad(cols, [0, 0.5, 1]), start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
  g.drawRadialGradient(grad([c(1, 1, 1, glow), c(1, 1, 1, 0)], [0, 1]), startCenter: CGPoint(x: 512, y: 40), startRadius: 0, endCenter: CGPoint(x: 512, y: 40), endRadius: 640, options: [])
  g.addPath(tile); g.setLineWidth(10); g.replacePathWithStrokedPath(); g.clip()
  g.drawLinearGradient(grad([c(1, 1, 1, 0.5), c(1, 1, 1, 0.04), c(0, 0, 0, 0.25)], [0, 0.45, 1]), start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
  g.restoreGState()
}
func bubble(_ rect: CGRect, flip: Bool = false) -> CGPath {
  let p = MessageMark.body(in: rect)
  guard flip else { return p }
  var t = CGAffineTransform(translationX: rect.midX * 2, y: 0).scaledBy(x: -1, y: 1)
  return p.copy(using: &t)!
}
func drawSolid(_ g: CGContext, _ path: CGPath, _ cols: [CGColor], _ l: [CGFloat], from: CGFloat, to: CGFloat, shadow: CGColor?, blur: CGFloat = 44, drop: CGFloat = 22, gloss: CGFloat = 0) {
  if let shadow {
    g.saveGState(); g.setShadow(offset: CGSize(width: 0, height: -drop), blur: blur, color: shadow)
    g.setFillColor(cols[cols.count / 2]); g.addPath(path); g.fillPath(); g.restoreGState()
  }
  g.saveGState(); g.addPath(path); g.clip()
  g.drawLinearGradient(grad(cols, l), start: CGPoint(x: 0, y: from), end: CGPoint(x: 0, y: to), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  if gloss > 0 {
    let b = path.boundingBox
    g.drawRadialGradient(grad([c(1, 1, 1, gloss), c(1, 1, 1, 0)], [0, 1]), startCenter: CGPoint(x: b.midX - b.width * 0.1, y: b.minY - b.height * 0.05), startRadius: 0, endCenter: CGPoint(x: b.midX, y: b.minY), endRadius: b.width * 0.75, options: [])
    g.addPath(path); g.setLineWidth(8); g.replacePathWithStrokedPath(); g.clip()
    g.drawLinearGradient(grad([c(1, 1, 1, 0.6), c(1, 1, 1, 0)], [0, 1]), start: CGPoint(x: 0, y: b.minY), end: CGPoint(x: 0, y: b.midY), options: [])
  }
  g.restoreGState()
}
let white: [CGColor] = [c(1, 1, 1), c(0.97, 0.98, 1), c(0.80, 0.87, 0.97)]
let blueTile: [CGColor] = [c(0.36, 0.76, 1), c(0.13, 0.50, 0.97), c(0.03, 0.30, 0.86)]
let blueInk: [CGColor] = [c(0.05, 0.33, 0.88), c(0.16, 0.55, 0.99), c(0.36, 0.74, 1)]
func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, in f: CGRect) -> CGPath {
  let u = f.width / 24
  return CGPath(ellipseIn: CGRect(x: f.minX + (x - r) * u, y: f.minY + (y - r) * u, width: 2 * r * u, height: 2 * r * u), transform: nil)
}
func render(_ name: String, _ body: (CGContext) -> Void) {
  let n = 1024
  let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let g = NSGraphicsContext(bitmapImageRep: bmp)!.cgContext
  g.translateBy(x: 0, y: CGFloat(n)); g.scaleBy(x: 1, y: -1)
  body(g)
  try! bmp.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
let face = CGRect(x: 200, y: 206, width: 624, height: 624)

import CoreText
let paper: [CGColor] = [c(1, 1, 1), c(0.96, 0.97, 0.98), c(0.87, 0.89, 0.93)]
let blueGloss: [CGColor] = [c(0.42, 0.80, 1), c(0.12, 0.50, 0.98), c(0.02, 0.27, 0.85)]
func rr(_ r: CGRect, _ k: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil) }
func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil) }
func text(_ g: CGContext, _ s: String, size: CGFloat, at p: CGPoint, color: CGColor, tracking: CGFloat = 0) {
  let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
  let bold = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .boldTrait, .boldTrait) ?? font
  let a = NSAttributedString(string: s, attributes: [.font: bold, .foregroundColor: NSColor(cgColor: color)!, .kern: tracking])
  let line = CTLineCreateWithAttributedString(a)
  let w = CTLineGetTypographicBounds(line, nil, nil, nil)
  g.saveGState(); g.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
  g.textPosition = CGPoint(x: p.x - CGFloat(w) / 2 + tracking / 2, y: p.y); CTLineDraw(line, g); g.restoreGState()
}


let black: [CGColor] = [c(0.17, 0.18, 0.20), c(0.07, 0.07, 0.09), c(0.01, 0.01, 0.02)]
struct RNG { var s: UInt64
  mutating func next() -> CGFloat { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; z ^= z >> 31; return CGFloat(z >> 11) / CGFloat(1 << 53) } }
let b = bubble(face)
let mid = CGPoint(x: face.midX, y: face.minY + face.height * 0.46)
func inside(_ p: CGPoint) -> Bool { b.contains(p) }
/// 0 inside; otherwise roughly how far outside, as a fraction of the radius.
func away(_ p: CGPoint) -> CGFloat {
  if inside(p) { return 0 }
  var k: CGFloat = 0.97
  while k > 0.3 { if inside(CGPoint(x: mid.x + (p.x - mid.x) * k, y: mid.y + (p.y - mid.y) * k)) { return 1 - k }; k -= 0.03 }
  return 1
}
func mix(_ a: [CGFloat], _ b: [CGFloat], _ t: CGFloat) -> [CGFloat] { zip(a, b).map { $0 + ($1 - $0) * t } }
func ramp(_ stops: [[CGFloat]], _ t: CGFloat) -> [CGFloat] {
  let x = min(max(t, 0), 0.9999) * CGFloat(stops.count - 1); let i = Int(x)
  return mix(stops[i], stops[i + 1], x - CGFloat(i))
}
func clipTile(_ g: CGContext, _ body: () -> Void) { g.saveGState(); g.addPath(tile); g.clip(); body(); g.restoreGState() }
func halo(_ g: CGContext, _ col: CGColor, _ blur: CGFloat) {
  clipTile(g) { g.setShadow(offset: .zero, blur: blur, color: col); g.setFillColor(col); g.addPath(b); g.fillPath() }
}


var glowTint = (0.93, 1.0, 0.96), bounceTint = (0.55, 0.93, 0.66)
let green: [CGColor] = [c(0.40, 0.97, 0.45), c(0.16, 0.86, 0.28), c(0.03, 0.72, 0.16)]
let ink = c(0, 0.30, 0.06, 0.40)
func shadowed(_ g: CGContext, _ body: () -> Void) {
  g.saveGState(); g.addPath(tile); g.clip(); g.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: ink)
  g.beginTransparencyLayer(auxiliaryInfo: nil); body(); g.endTransparencyLayer(); g.restoreGState()
}


let W1 = c(1, 1, 1)
func sq(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> CGRect { CGRect(x: x, y: y, width: s, height: s) }
/// Soft top-to-bottom shading over whatever white was just drawn.
func shade(_ g: CGContext) {
  g.setBlendMode(.sourceAtop)
  g.drawLinearGradient(grad([c(1, 1, 1, 0), c(0.80, 0.94, 0.82, 1)], [0.45, 1]), start: CGPoint(x: 0, y: face.minY), end: CGPoint(x: 0, y: face.maxY), options: [])
  g.setBlendMode(.normal)
}


let bayer: [[CGFloat]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
func thresh(_ i: Int, _ j: Int) -> CGFloat { (bayer[((j % 4) + 4) % 4][((i % 4) + 4) % 4] + 0.5) / 16 }
func lit(_ p: CGPoint, _ boost: CGFloat = 1.12) -> CGFloat { boost - hypot(p.x - (mid.x - 110), p.y - (mid.y - 130)) / 470 }
/// Walks a pixel grid centred on the tile. `cell` gets column, row, the square, and its centre.
func grid(_ s: CGFloat, _ cell: (Int, Int, CGRect, CGPoint) -> Void) {
  let n = Int(420 / s) + 1
  for j in -n..<n { for i in -n..<n { let x = 512 + CGFloat(i) * s, y = 512 + CGFloat(j) * s; cell(i, j, sq(x, y, s + 0.4), CGPoint(x: x + s / 2, y: y + s / 2)) } }
}
func isRim(_ p: CGPoint, _ s: CGFloat) -> Bool {
  !inside(CGPoint(x: p.x + s, y: p.y)) || !inside(CGPoint(x: p.x - s, y: p.y)) || !inside(CGPoint(x: p.x, y: p.y + s)) || !inside(CGPoint(x: p.x, y: p.y - s))
}

let whiteG: [CGColor] = [c(1, 1, 1), c(0.99, 1, 0.99), c(0.90, 0.97, 0.91)]
func base(_ g: CGContext) { drawSolid(g, b, whiteG, [0, 0.55, 1], from: face.minY + 60, to: face.maxY - 50, shadow: ink) }
func inBubble(_ g: CGContext, _ body: () -> Void) { g.saveGState(); g.addPath(b); g.clip(); body(); g.restoreGState() }
/// 0 at the lit top-left, rising to about 1 at the far corner.
func dusk(_ p: CGPoint) -> CGFloat { hypot(p.x - (mid.x - 130), p.y - (mid.y - 150)) / 520 }
let tint = c(0.20, 0.82, 0.34)
func rim(_ g: CGContext) {
  g.saveGState(); g.addPath(b); g.setLineWidth(8); g.replacePathWithStrokedPath(); g.clip()
  g.drawLinearGradient(grad([c(1, 1, 1, 1), c(1, 1, 1, 0.6)], [0, 1]), start: CGPoint(x: 0, y: face.minY), end: CGPoint(x: 0, y: face.maxY), options: []); g.restoreGState()
}


func hash(_ x: Int, _ y: Int, _ k: Int = 0) -> Double { var h = UInt64(bitPattern: Int64(x &* 374761393 &+ y &* 668265263 &+ k &* 2147483647)); h = (h ^ (h >> 13)) &* 1274126177; h ^= h >> 16; return Double(h & 0xFFFFFF) / Double(0xFFFFFF) }
func vnoise(_ x: Double, _ y: Double) -> Double {
  let xi = Int(floor(x)), yi = Int(floor(y)); var fx = x - floor(x), fy = y - floor(y); fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy)
  let a = hash(xi, yi), b0 = hash(xi + 1, yi), c0 = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
  return a + (b0 - a) * fx + (c0 - a) * fy + (a - b0 - c0 + d) * fx * fy
}
func fbm(_ x: Double, _ y: Double) -> Double { var s = 0.0, a = 0.5, f = 1.0; for _ in 0..<4 { s += a * vnoise(x * f, y * f); a *= 0.5; f *= 2.03 }; return s }
func pal(_ t: Double, _ ph: Double) -> Double { 0.5 + 0.5 * cos(6.2832 * (t + ph)) }
/// Runs `f(u, v)` for every pixel of the bubble's box and paints the result inside the bubble.
func shader(_ g: CGContext, _ f: (Double, Double) -> (Double, Double, Double)) {
  let n = 720; var px = [UInt8](repeating: 255, count: n * n * 4)
  for j in 0..<n { for i in 0..<n { let (r, gg, bl) = f(Double(i) / Double(n), Double(j) / Double(n)); let o = (j * n + i) * 4
    px[o] = UInt8(min(max(r, 0), 1) * 255); px[o + 1] = UInt8(min(max(gg, 0), 1) * 255); px[o + 2] = UInt8(min(max(bl, 0), 1) * 255) } }
  let img = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
  g.saveGState(); g.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: ink); g.addPath(b); g.setFillColor(W1); g.fillPath(); g.restoreGState()
  // The context is flipped, so flip the image back to keep v running downward.
  inBubble(g) { g.interpolationQuality = .high; g.translateBy(x: 0, y: face.minY + face.maxY); g.scaleBy(x: 1, y: -1); g.draw(img, in: face) }
}
/// Dome coordinates: centre of the round part is (0,0), edge at radius 1.
func dome(_ u: Double, _ v: Double) -> (Double, Double, Double) { let x = (u * 24 - 12) / 10, y = (v * 24 - 11.2) / 8.8; return (x, y, sqrt(x * x + y * y)) }


// Distance from every pixel to the bubble's real edge, tail included.
let N = 1440
let dist: [Double] = {
  var d = [Double](repeating: 0, count: N * N); let big = 1e6
  for j in 0..<N { for i in 0..<N { d[j * N + i] = inside(CGPoint(x: face.minX + (CGFloat(i) + 0.5) / CGFloat(N) * face.width, y: face.minY + (CGFloat(j) + 0.5) / CGFloat(N) * face.height)) ? big : 0 } }
  func at(_ i: Int, _ j: Int) -> Double { i < 0 || j < 0 || i >= N || j >= N ? 0 : d[j * N + i] }
  for j in 0..<N { for i in 0..<N { let k = j * N + i; if d[k] > 0 { d[k] = min(d[k], at(i - 1, j) + 1, at(i, j - 1) + 1, at(i - 1, j - 1) + 1.4142, at(i + 1, j - 1) + 1.4142) } } }
  for j in stride(from: N - 1, through: 0, by: -1) { for i in stride(from: N - 1, through: 0, by: -1) { let k = j * N + i; if d[k] > 0 { d[k] = min(d[k], at(i + 1, j) + 1, at(i, j + 1) + 1, at(i + 1, j + 1) + 1.4142, at(i - 1, j + 1) + 1.4142) } } }
  return d
}()
func blur(_ a: [Double], _ r: Int) -> [Double] {
  var src = a, out = a
  for pass in 0..<4 { let horiz = pass % 2 == 0
    for j in 0..<N { for i in 0..<N { var s = 0.0; for k in -r...r { let ii = min(max((horiz ? i : j) + k, 0), N - 1); s += horiz ? src[j * N + ii] : src[ii * N + i] }; out[j * N + i] = s / Double(2 * r + 1) } }
    src = out }
  return out
}
/// A surface raised from the edge over `bevel` pixels. Returns height 0...1 and unit normals.
struct Relief { var h: [Double], nx: [Double], ny: [Double], nz: [Double]
  init(bevel: Double, soften: Int, steep: Double = 1) {
    var hh = dist.map { d -> Double in let t = min(d / bevel, 1); return sqrt(max(0, 1 - (1 - t) * (1 - t))) }
    hh = blur(hh, soften); h = hh
    nx = hh; ny = hh; nz = hh
    for j in 0..<N { for i in 0..<N { let k = j * N + i
      let gx = (hh[j * N + min(i + 1, N - 1)] - hh[j * N + max(i - 1, 0)]) * 0.5 * bevel * steep
      let gy = (hh[min(j + 1, N - 1) * N + i] - hh[max(j - 1, 0) * N + i]) * 0.5 * bevel * steep
      let l = sqrt(gx * gx + gy * gy + 1); nx[k] = -gx / l; ny[k] = -gy / l; nz[k] = 1 / l } }
  }
}
/// Per-pixel paint inside the bubble; `f(index, u, v)` returns straight RGBA.
func paint(_ g: CGContext, _ f: (Int, Double, Double) -> (Double, Double, Double, Double)) {
  var px = [UInt8](repeating: 0, count: N * N * 4)
  for j in 0..<N { for i in 0..<N { let k = j * N + i; let (r, gg, bl, a0) = f(k, Double(i) / Double(N), Double(j) / Double(N)); let a = min(max(a0, 0), 1); let o = k * 4
    px[o] = UInt8(min(max(r, 0), 1) * a * 255); px[o + 1] = UInt8(min(max(gg, 0), 1) * a * 255); px[o + 2] = UInt8(min(max(bl, 0), 1) * a * 255); px[o + 3] = UInt8(a * 255) } }
  let img = CGImage(width: N, height: N, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: N * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
  inBubble(g) { g.interpolationQuality = .high; g.translateBy(x: 0, y: face.minY + face.maxY); g.scaleBy(x: 1, y: -1); g.draw(img, in: face) }
}
func under(_ g: CGContext, _ col: CGColor, _ shadow: CGColor = ink) { g.saveGState(); g.setShadow(offset: CGSize(width: 0, height: -16), blur: 30, color: shadow); g.addPath(b); g.setFillColor(col); g.fillPath(); g.restoreGState() }
func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }
func lerp3(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) { (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t) }
func spec(_ r: Relief, _ k: Int, _ p: Double) -> Double { pow(max(0, r.nx[k] * -0.42 + r.ny[k] * -0.58 + r.nz[k] * 0.70), p) }

let puffy = Relief(bevel: 150, soften: 7)
let bevel = Relief(bevel: 60, soften: 4)

/// Inflates the outline like a balloon (a Poisson solve), so the surface has no creases
/// where the tail joins the body.
let metal: Relief = {
  let M = 360, q = N / M; var h = [Double](repeating: 0, count: M * M); var m = [Bool](repeating: false, count: M * M)
  for j in 0..<M { for i in 0..<M { m[j * M + i] = dist[(j * q + q / 2) * N + i * q + q / 2] > 0 } }
  for _ in 0..<3000 { for j in 1..<(M - 1) { for i in 1..<(M - 1) { let k = j * M + i; if m[k] { let sum: Double = h[k - 1] + h[k + 1] + h[k - M] + h[k + M] + 1.0; let t: Double = sum / 4.0 - h[k]; h[k] += 1.97 * t } } } }
  let top = h.max()!; var big = [Double](repeating: 0, count: N * N)
  for j in 0..<N { for i in 0..<N { let lim: Double = Double(M) - 1.001; let x: Double = min(max((Double(i) + 0.5) / Double(q) - 0.5, 0.0), lim); let y: Double = min(max((Double(j) + 0.5) / Double(q) - 0.5, 0.0), lim); let xi = Int(x), yi = Int(y); let fx = x - Double(xi), fy = y - Double(yi)
    let o: Int = yi * M + xi; let a0: Double = h[o] * (1 - fx) + h[o + 1] * fx; let a1: Double = h[o + M] * (1 - fx) + h[o + M + 1] * fx; let v: Double = a0 * (1 - fy) + a1 * fy
    big[j * N + i] = sqrt(max(v, 0) / top) } }
  big = blur(blur(blur(big, 14), 14), 10)
  var r = bevel; r.h = big; let S = 460.0
  for j in 0..<N { for i in 0..<N { let k = j * N + i
    let gx = (big[j * N + min(i + 1, N - 1)] - big[j * N + max(i - 1, 0)]) * 0.5 * S, gy = (big[min(j + 1, N - 1) * N + i] - big[max(j - 1, 0) * N + i]) * 0.5 * S
    let l = sqrt(gx * gx + gy * gy + 1); r.nx[k] = -gx / l; r.ny[k] = -gy / l; r.nz[k] = 1 / l } }
  return r
}()

/// What a mirror facing `up` (-1 ground ... 1 sky) would show: pale sky, a dark horizon, lit green ground.
func env(_ up: Double) -> (Double, Double, Double) {
  let sky = lerp3((0.80, 0.93, 0.84), (1, 1, 1), smooth(0.2, 1.0, up))
  let ground = lerp3((0.16, 0.50, 0.28), (0.78, 0.98, 0.80), smooth(-0.10, -0.75, up))
  return lerp3(ground, sky, smooth(-0.10, 0.10, up))
}


func silver(_ up: Double) -> (Double, Double, Double) {
  let sky = lerp3((0.82, 0.86, 0.88), (1, 1, 1), smooth(0.2, 1.0, up))
  let ground = lerp3((0.22, 0.27, 0.28), (0.80, 0.93, 0.83), smooth(-0.10, -0.75, up))
  return lerp3(ground, sky, smooth(-0.10, 0.10, up))
}


/// Polished metal without a hard horizon: deep tone, but every edge of the band is a gradient,
/// plus a faint second band in the sky and a tight hot highlight.
func env3(_ up: Double, silver: Bool) -> (Double, Double, Double) {
  let pale: (Double, Double, Double) = silver ? (0.80, 0.85, 0.88) : (0.78, 0.93, 0.83)
  var sky = lerp3(pale, (1, 1, 1), smooth(0.15, 0.85, up))
  let band = smooth(0.22, 0.54, up) * smooth(0.90, 0.56, up) * 0.11
  sky = (sky.0 - band, sky.1 - band * 0.8, sky.2 - band * 0.9)
  let dark: (Double, Double, Double) = silver ? (0.30, 0.36, 0.38) : (0.20, 0.54, 0.33)
  let ground = lerp3(dark, silver ? (0.86, 0.95, 0.89) : (0.80, 0.97, 0.83), smooth(-0.10, -0.85, up))
  return lerp3(ground, sky, smooth(-0.50, 0.36, up))
}

/// A soft four-point glint: a wide bloom, then thin rays that fade to nothing at their tips.
func glint(_ g: CGContext, _ p: CGPoint, _ r: CGFloat, _ a: CGFloat) {
  let space = CGColorSpaceCreateDeviceRGB()
  func bloom(_ radius: CGFloat, _ alpha: CGFloat) {
    let grad = CGGradient(colorsSpace: space, colors: [c(1, 1, 1, alpha), c(1, 1, 1, alpha * 0.35), c(1, 1, 1, 0)] as CFArray, locations: [0, 0.35, 1])!
    g.drawRadialGradient(grad, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
  }
  func star(_ radius: CGFloat, _ pinch: CGFloat, _ turn: CGFloat) -> CGPath {
    let path = CGMutablePath(); let pts: [(CGFloat, CGFloat)] = [(0, -1), (1, 0), (0, 1), (-1, 0)]
    path.move(to: CGPoint(x: 0, y: -radius))
    for i in 1...4 { let f = pts[i - 1], t = pts[i % 4]
      path.addQuadCurve(to: CGPoint(x: t.0 * radius, y: t.1 * radius), control: CGPoint(x: (f.0 + t.0) * radius * pinch, y: (f.1 + t.1) * radius * pinch)) }
    path.closeSubpath()
    var m = CGAffineTransform(translationX: p.x, y: p.y).rotated(by: turn); return path.copy(using: &m)!
  }
  g.saveGState()
  bloom(r * 1.15, 0.55 * a); bloom(r * 0.42, 0.9 * a)
  g.setShadow(offset: .zero, blur: r * 0.16, color: c(1, 1, 1, 0.9 * a))
  for (radius, pinch, turn, alpha) in [(r, 0.035, 0.0, 1.0), (r * 0.42, 0.06, 0.785, 0.55)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
    g.saveGState(); g.addPath(star(radius, pinch, turn)); g.clip()
    let grad = CGGradient(colorsSpace: space, colors: [c(1, 1, 1, alpha * a), c(1, 1, 1, alpha * a * 0.75), c(1, 1, 1, 0)] as CFArray, locations: [0, 0.3, 1])!
    g.drawRadialGradient(grad, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: []); g.restoreGState()
  }
  g.restoreGState()
}

/// A lens flare: a hot core, a wide bloom, and long hair-thin streaks that fade out along their length.
func flare(_ g: CGContext, _ p: CGPoint) {
  let space = CGColorSpaceCreateDeviceRGB()
  func glow(_ stops: [(CGFloat, CGFloat)], _ tint: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { c(tint.0, tint.1, tint.2, $0.1) } as CFArray, locations: stops.map { $0.0 })!
  }
  func streak(_ length: CGFloat, _ thick: CGFloat, _ turn: CGFloat, _ alpha: CGFloat, inward: CGFloat = 1) {
    for side in [CGFloat(1), -1] { let len = side > 0 ? length : length * inward
    g.saveGState(); g.translateBy(x: p.x, y: p.y); g.rotate(by: turn * .pi / 180); g.clip(to: CGRect(x: side > 0 ? 0 : -len, y: -thick, width: len, height: thick * 2)); g.scaleBy(x: len, y: thick)
    g.drawRadialGradient(glow([(0, alpha), (0.20, alpha * 0.85), (0.55, alpha * 0.30), (1, 0)]), startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
    g.restoreGState() }
  }
  g.saveGState(); g.addPath(tile); g.clip(); g.setBlendMode(.plusLighter)
  g.drawRadialGradient(glow([(0, 0.62), (0.25, 0.30), (0.6, 0.09), (1, 0)], (glowTint.0 - 0.01, glowTint.1, glowTint.2 - 0.02)), startCenter: p, startRadius: 0, endCenter: p, endRadius: 270, options: [])
  g.drawRadialGradient(glow([(0, 0.9), (0.4, 0.35), (1, 0)]), startCenter: p, startRadius: 0, endCenter: p, endRadius: 92, options: [])
  streak(400, 44, -45, 0.16, inward: 0.45); streak(400, 24, -45, 0.34, inward: 0.45); streak(400, 8.5, -45, 1.0, inward: 0.45); streak(330, 3.2, -45, 0.8, inward: 0.45)
  streak(260, 36, 45, 0.14); streak(260, 19, 45, 0.30); streak(260, 7, 45, 1.0); streak(210, 2.8, 45, 0.8)
  streak(120, 10, 0, 0.22); streak(120, 4, 0, 0.8); streak(120, 10, 90, 0.22); streak(120, 4, 90, 0.8)
  // The rays swell into the core along concave curves, so the flare reads as a sparkle and not as crossed lines.
  let tips: [CGPoint] = [CGPoint(x: 330, y: 0), CGPoint(x: 0, y: 215), CGPoint(x: -160, y: 0), CGPoint(x: 0, y: -215)]
  for (scale, power, alpha) in [(1.0, 5.2, 0.42), (0.60, 3.8, 0.60)] as [(CGFloat, Double, CGFloat)] {
    let path = CGMutablePath()
    for step in 0..<400 { let a = Double(step) / 400 * 2 * .pi; let cs = cos(a), sn = sin(a)
      let rx = (cs >= 0 ? tips[0].x : -tips[2].x) * scale, ry = tips[1].y * scale
      let q = CGPoint(x: rx * CGFloat((cs < 0 ? -1 : 1) * pow(abs(cs), power)), y: ry * CGFloat((sn < 0 ? -1 : 1) * pow(abs(sn), power)))
      if step == 0 { path.move(to: q) } else { path.addLine(to: q) } }
    path.closeSubpath()
    g.saveGState(); g.translateBy(x: p.x, y: p.y); g.rotate(by: -45 * .pi / 180); g.addPath(path); g.clip()
    g.drawRadialGradient(glow([(0, alpha), (0.30, alpha * 0.7), (0.70, alpha * 0.22), (1, 0)]), startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 330 * scale, options: [])
    g.restoreGState()
  }
  g.drawRadialGradient(glow([(0, 1), (0.5, 1), (1, 0)]), startCenter: p, startRadius: 0, endCenter: p, endRadius: 20, options: [])
  g.restoreGState()
}
func chrome3(_ name: String, warp: Double, silver: Bool) {
  render(name) { g in
    drawTile(g, green, glow: 0.25); under(g, W1)
    paint(g) { k, u, v in
      let w = fbm(u * 1.6 + 1.5, v * 1.6) - 0.5, w2 = fbm(u * 1.6 + 9, v * 1.6 + 4) - 0.5
      var x = metal.nx[k] + w * warp * metal.nz[k], y = metal.ny[k] + w2 * warp * metal.nz[k], z = metal.nz[k]; let l = sqrt(x * x + y * y + z * z); x /= l; y /= l; z /= l
      let col = env3(1.9 * (0.14 - 0.60 * x * x - y) + 0.10 * x, silver: silver)
      let d = max(0, x * -0.42 + y * -0.58 + z * 0.70); let s = pow(d, 110) * 1.1 + pow(d, 14) * 0.10
      let edge = 1 - 0.22 * pow(1 - z, 2.2)
      return (col.0 * edge + s, col.1 * edge + s, col.2 * edge + s, 1) }
    rim(g)
    flare(g, CGPoint(x: 690, y: 320))
  }
}

/// Chrome silver with a dreamy glow: a wide soft halo hugging the outline, a rim of light,
/// and bloom where the bright parts of the metal haze into their surroundings.
func dreamy(_ name: String, warm: Bool) {
  render(name) { g in
    drawTile(g, green, glow: 0.25)
    for (radius, alpha) in [(110.0, 0.55), (46.0, 0.60), (16.0, 0.50)] as [(CGFloat, CGFloat)] {
      g.saveGState(); g.addPath(tile); g.clip(); g.setShadow(offset: .zero, blur: radius, color: c(glowTint.0, glowTint.1, glowTint.2, alpha)); g.addPath(b); g.setFillColor(W1); g.fillPath(); g.restoreGState() }
    under(g, W1)
    var bright = [Double](repeating: 0, count: N * N)
    paint(g) { k, u, v in
      let x = metal.nx[k], y = metal.ny[k], z = metal.nz[k]
      let col = env3(1.9 * (0.14 - 0.60 * x * x - y) + 0.10 * x, silver: true)
      let d = max(0, x * -0.42 + y * -0.58 + z * 0.70); let s = pow(d, 110) * 1.1 + pow(d, 14) * 0.10
      let edge = 1 - 0.22 * pow(1 - z, 2.2); let light = pow(1 - z, 2.6) * 0.85
      var out = (col.0 * edge + s + light, col.1 * edge + s + light, col.2 * edge + s + light)
      if warm { let du = u - 0.13, dv = v - 0.56; let w = exp(-(du * du / 0.010 + dv * dv / 0.014)) * (0.2 + 0.8 * pow(1 - z, 0.8))
        out = (out.0 + w * 0.45, out.1 + (0.62 - out.1) * w * 0.6, out.2 + (0.30 - out.2) * w * 0.75) }
      bright[k] = dist[k] > 0 ? smooth(0.62, 1.0, (out.0 + out.1 + out.2) / 3) : 0
      return (out.0, out.1, out.2, 1) }
    let haze = blur(blur(bright, 34), 34)
    paint(g) { k, _, _ in (1, 1, 1, haze[k] * 0.42) }
    rim(g)
    flare(g, CGPoint(x: 690, y: 320))
  }
}

func stops(_ t: Double, _ list: [(Double, (Double, Double, Double))]) -> (Double, Double, Double) {
  if t <= list[0].0 { return list[0].1 }
  for i in 1..<list.count where t <= list[i].0 { let a = list[i - 1], b = list[i]; return lerp3(a.1, b.1, smooth(a.0, b.0, t)) }
  return list[list.count - 1].1
}
let navyRamp: [(Double, (Double, Double, Double))] = [
  (0.00, (0.88, 0.92, 1.0)), (0.07, (0.08, 0.10, 0.28)), (0.22, (0.16, 0.22, 0.52)), (0.285, (1.0, 0.56, 0.14)), (0.315, (0.92, 0.22, 0.42)),
  (0.345, (0.45, 0.85, 1.0)), (0.43, (0.76, 0.84, 1.0)), (0.62, (1, 1, 1)), (1.0, (1, 1, 1))]
let silverRamp: [(Double, (Double, Double, Double))] = [
  (0.00, (0.92, 0.95, 1.0)), (0.07, (0.30, 0.36, 0.46)), (0.20, (0.52, 0.60, 0.74)), (0.265, (1.0, 0.70, 0.30)), (0.30, (0.86, 0.50, 0.80)),
  (0.335, (0.50, 0.86, 1.0)), (0.43, (0.84, 0.90, 1.0)), (0.60, (1, 1, 1)), (1.0, (1, 1, 1))]
/// Iridescent chrome: bands run parallel to the outline, a white core, a dark band near the edge,
/// and a hair of orange-to-cyan fringe where the two meet.
func irid(_ name: String, ramp: [(Double, (Double, Double, Double))], warp: Double, halo: Bool) {
  render(name) { g in
    drawTile(g, green, glow: 0.25)
    if halo { for (radius, alpha) in [(90.0, 0.45), (30.0, 0.50)] as [(CGFloat, CGFloat)] {
      g.saveGState(); g.addPath(tile); g.clip(); g.setShadow(offset: .zero, blur: radius, color: c(glowTint.0, glowTint.1, glowTint.2, alpha)); g.addPath(b); g.setFillColor(W1); g.fillPath(); g.restoreGState() } }
    under(g, W1)
    paint(g) { k, u, v in
      let x = metal.nx[k], y = metal.ny[k], z = metal.nz[k]
      let flow = (fbm(u * 2.2 + 3, v * 2.2 + 1) - 0.5) * warp
      let p = (pow(metal.h[k], 2.3) * 0.80 + 0.26 * (-0.45 * x - 0.75 * y) + flow) / 1.55 + 0.03
      let col = stops(p, ramp)
      let d = max(0, x * -0.42 + y * -0.58 + z * 0.70); let s = pow(d, 90) * 0.9
      return (col.0 + s, col.1 + s, col.2 + s, 1) }
    rim(g)
    flare(g, CGPoint(x: 690, y: 320))
  }
}

/// The bubble's body without its tail, as an ellipse in the paint grid's 0...1 space.
let oval: (cx: Double, cy: Double, rx: Double, ry: Double) = {
  var best = (0, 0, 0)
  for j in 0..<N { var lo = -1, hi = -1; for i in 0..<N where dist[j * N + i] > 0 { if lo < 0 { lo = i }; hi = i }; if hi - lo > best.0 { best = (hi - lo, lo, hi) } }
  let cx = (best.1 + best.2) / 2; var top = -1, bottom = -1
  for j in 0..<N where dist[j * N + cx] > 0 { if top < 0 { top = j }; bottom = j }
  return (Double(cx) / Double(N), Double(top + bottom) / 2 / Double(N), Double(best.0) / 2 / Double(N), Double(bottom - top) / 2 / Double(N))
}()
func bump(_ c: Double, _ w: Double, _ x: Double) -> Double { let t = (x - c) / w; return exp(-t * t) }
/// The chrome-silver reflection, with thin iridescent fringes where the dark band meets the light:
/// orange on its upper edge, cyan and violet on its lower one.
func fringe(_ name: String, dark: (Double, Double, Double), warp: Double, strength: Double, tilt: Double = 0, curve: Double = 0.60, soft: Double = 0.12, arc: Double = 0, real: Bool = false, cine: Bool = false, haze: (Double, Double, Double) = (0.76, 0.83, 0.93), top: (Double, Double, Double) = (1, 1, 1), pale: (Double, Double, Double) = (0.88, 0.95, 0.98), soften: Double = 0, tileCols: [CGColor] = green) {
  // One radius both ways: the band is what a ball would reflect, not what an oval would.
  let ball = (oval.rx + oval.ry) / 2
  let ca = cos(tilt * .pi / 180), sa = sin(tilt * .pi / 180)
  render(name) { g in
    drawTile(g, tileCols, glow: 0.25)
    if cine {
      // A lens darkens toward its corners; the light side stays open.
      g.saveGState(); g.addPath(tile); g.clip()
      let shade = CGGradient(colorsSpace: nil, colors: [c(0, 0.16, 0.06, 0), c(0, 0.16, 0.06, 0.55)] as CFArray, locations: [0.42, 1])!
      g.drawRadialGradient(shade, startCenter: CGPoint(x: 600, y: 400), startRadius: 0, endCenter: CGPoint(x: 600, y: 400), endRadius: 760, options: [.drawsAfterEndLocation])
      g.restoreGState()
    }
    for (radius, alpha) in [(90.0, 0.40), (30.0, 0.45)] as [(CGFloat, CGFloat)] {
      g.saveGState(); g.addPath(tile); g.clip(); g.setShadow(offset: .zero, blur: radius, color: c(glowTint.0, glowTint.1, glowTint.2, alpha)); g.addPath(b); g.setFillColor(W1); g.fillPath(); g.restoreGState() }
    under(g, W1)
    paint(g) { k, u, v in
      let w = fbm(u * 1.8 + 1.5, v * 1.8) - 0.5, w2 = fbm(u * 1.8 + 9, v * 1.8 + 4) - 0.5
      var x = metal.nx[k] + w * warp * metal.nz[k], y = metal.ny[k] + w2 * warp * metal.nz[k], z = metal.nz[k]; let l = sqrt(x * x + y * y + z * z); x /= l; y /= l; z /= l
      // The reflection is taken off a plain rounded dome fitted to the body, so the tail never bends it.
      let eu = (u - oval.cx) / ball, ev = (v - oval.cy) / ball; let rr = min(sqrt(eu * eu + ev * ev), 1.0), sc = rr / max(sqrt(eu * eu + ev * ev), 1e-6)
      var ox = eu * sc * 0.92 + w * warp, oy = ev * sc * 0.92 + w2 * warp, oz = sqrt(max(1 - rr * rr, 0.0)) + soft; let ol = sqrt(ox * ox + oy * oy + oz * oz); ox /= ol; oy /= ol; oz /= ol
      // The horizon turns with the light, so the band and the flare agree on where the sun is.
      let across = ox * ca + oy * sa, along = ox * sa - oy * ca
      // With `arc` set the band is a ring of even width about a point up the light's way, so its ends stay blunt.
      let px = eu + w * warp - sa * arc, py = ev + w2 * warp + ca * arc
      let up = arc > 0 ? 1.9 * (arc + 0.14 - sqrt(px * px + py * py)) : 1.9 * (0.14 - curve * across * across + along)
      var col: (Double, Double, Double)
      if real {
        // A real mirror ball: a crisp horizon, ground that pales with depth, a band that washes out
        // toward the rim, and the green tile bouncing back into the underside.
        let horizon = smooth(-0.14 - soften, 0.12 + soften, up), rimward = pow(1 - z, 1.6)
        // Cinematic: a warm glow sits on the horizon under a cooler sky, as at golden hour.
        let sky = cine
          ? lerp3((1.0, 0.86, 0.66), lerp3((0.72, 0.82, 0.95), (1, 1, 1), smooth(0.25, 1.1, up)), smooth(0.0, 0.42, up))
          : lerp3(haze, top, smooth(0.0, 0.9, up))
        let ground = lerp3(dark, pale, pow(smooth(0.0, -1.15, up), 0.8))
        col = lerp3(ground, sky, horizon)
        col = lerp3(col, lerp3(haze, pale, 0.5), min(rimward * 0.7, 1) * (1 - horizon))
        col = lerp3(col, bounceTint, min(smooth(-0.7, -1.7, up) * 0.40 + rimward * 0.18, 1))
        if cine {
          func grade(_ v: Double) -> Double { let x = min(max(v, 0), 1); return x + 0.45 * (x * x * (3 - 2 * x) - x) }
          col = (grade(col.0), grade(col.1), grade(col.2))
        }
      } else {
        let sky = lerp3((0.82, 0.87, 0.94), (1, 1, 1), smooth(0.15, 0.85, up))
        let ground = lerp3(dark, (0.86, 0.93, 1.0), smooth(-0.10, -0.85, up))
        col = lerp3(ground, sky, smooth(-0.42, 0.26, up))
      }
      let o = bump(0.10, 0.075, up) * strength, m = bump(0.00, 0.05, up) * strength * 0.6, cy = bump(real ? -0.80 : -0.56, 0.10, up) * strength * 0.8, vi = bump(real ? -1.0 : -0.72, 0.08, up) * strength * 0.45
      col = lerp3(col, (1.0, 0.60, 0.16), o); col = lerp3(col, (0.92, 0.26, 0.40), m); col = lerp3(col, (0.40, 0.84, 1.0), cy); col = lerp3(col, (0.66, 0.50, 1.0), vi)
      let d = max(0, x * (tilt > 0 ? 0.42 : -0.42) + y * -0.58 + z * 0.70); let s = pow(d, 110) * 1.1 + pow(d, 14) * 0.10
      let light = pow(1 - z, 2.6) * 0.55
      return (col.0 + s + light, col.1 + s + light, col.2 + s + light, 1) }
    rim(g)
    flare(g, CGPoint(x: 690, y: 320))
  }
}
glowTint = (0.90, 0.96, 1.0); bounceTint = (0.56, 0.76, 1.0)
fringe("B1", dark: (0.44, 0.46, 0.49), warp: 0, strength: 0.25, tilt: 10, arc: 1.0, real: true, haze: (0.72, 0.74, 0.77), top: (0.95, 0.96, 0.97), pale: (0.80, 0.83, 0.85), soften: 0.16, tileCols: blueTile)
fringe("B2", dark: (0.44, 0.46, 0.49), warp: 0, strength: 0.25, tilt: 10, arc: 1.0, real: true, haze: (0.72, 0.74, 0.77), top: (0.95, 0.96, 0.97), pale: (0.80, 0.83, 0.85), soften: 0.16, tileCols: blueGloss)
