import AppKit
import MaxBrand
import SwiftUI

/// One 16-unit grid, one round pen, and up to three layers per glyph: a faint
/// fill, the strokes, and solid dots.
enum Glyph: CaseIterable {
  case messages, contacts, sending, connection, details, preferences
  case refresh, lock, document, warning, check

  fileprivate struct Art {
    var wash = Path()
    var lines = Path()
    var dots = Path()
  }

  fileprivate var art: Art {
    var art = Art()
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
      Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
      Path(
        roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .continuous)
    }
    func line(_ points: (CGFloat, CGFloat)...) {
      art.lines.move(to: CGPoint(x: points[0].0, y: points[0].1))
      for point in points.dropFirst() { art.lines.addLine(to: CGPoint(x: point.0, y: point.1)) }
    }
    /// A closed outline that also carries the faint fill.
    func solid(_ path: Path) {
      art.wash.addPath(path)
      art.lines.addPath(path)
    }
    switch self {
    case .messages:
      // The product's own face, small.
      solid(Path(MessageMark.body(in: CGRect(x: 0, y: 0, width: 16, height: 16))))
      art.dots.addPath(circle(7.1, 6.9, 0.95))
      art.dots.addPath(circle(10.2, 6.7, 0.85))
    case .contacts:
      solid(circle(8, 5.3, 2.7))
      var shoulders = Path()
      shoulders.move(to: CGPoint(x: 2.8, y: 13.8))
      shoulders.addCurve(
        to: CGPoint(x: 13.2, y: 13.8), control1: CGPoint(x: 3.4, y: 9), control2: CGPoint(x: 12.6, y: 9))
      shoulders.closeSubpath()
      solid(shoulders)
    case .sending:
      solid(circle(8, 8, 6.2))
      line((8, 11.2), (8, 5))
      line((5.5, 7.4), (8, 4.9), (10.5, 7.4))
    case .connection:
      solid(circle(5.5, 8, 3.4))
      solid(circle(10.5, 8, 3.4))
    case .details:
      solid(circle(8, 8, 6.2))
      line((8, 7.6), (8, 11))
      art.dots.addPath(circle(8, 5.1, 0.9))
    case .preferences:
      line((2.4, 5), (13.6, 5))
      line((2.4, 11), (13.6, 11))
      art.dots.addPath(circle(10.3, 5, 2))
      art.dots.addPath(circle(5.7, 11, 2))
    case .refresh:
      art.lines.addArc(
        center: CGPoint(x: 8, y: 8), radius: 5.4, startAngle: .degrees(-45),
        endAngle: .degrees(270), clockwise: false)
      line((11.3, 1.9), (12, 4.7), (14.8, 4))
    case .lock:
      solid(box(3.2, 7, 9.6, 7, 2.2))
      art.lines.move(to: CGPoint(x: 5.4, y: 7))
      art.lines.addLine(to: CGPoint(x: 5.4, y: 5.2))
      art.lines.addCurve(
        to: CGPoint(x: 10.6, y: 5.2), control1: CGPoint(x: 5.4, y: 1.4),
        control2: CGPoint(x: 10.6, y: 1.4))
      art.lines.addLine(to: CGPoint(x: 10.6, y: 7))
      art.dots.addPath(circle(8, 10.5, 0.9))
    case .document:
      solid(box(3.2, 1.8, 9.6, 12.4, 2.2))
      line((6, 6), (10, 6))
      line((6, 9.2), (8.8, 9.2))
    case .warning:
      var triangle = Path()
      triangle.move(to: CGPoint(x: 8, y: 2.6))
      triangle.addLine(to: CGPoint(x: 14, y: 13))
      triangle.addLine(to: CGPoint(x: 2, y: 13))
      triangle.closeSubpath()
      solid(triangle)
      line((8, 6.6), (8, 9.2))
      art.dots.addPath(circle(8, 11.1, 0.8))
    case .check:
      line((3.4, 8.4), (6.6, 11.4), (12.6, 4.8))
    }
    return art
  }
}

enum Pen {
  /// One stroke weight that grows with the glyph, never thinner than 1.2.
  static func width(_ size: CGFloat) -> CGFloat { max(1.2, size * 0.1) }
}

private struct GridPath: Shape {
  let path: Path
  let grid: CGFloat
  func path(in rect: CGRect) -> Path {
    path.applying(CGAffineTransform(scaleX: rect.width / grid, y: rect.height / grid))
  }
}

struct AppGlyph: View {
  let glyph: Glyph
  var size: CGFloat = 16

  var body: some View {
    let art = glyph.art
    ZStack {
      GridPath(path: art.wash, grid: 16).fill().opacity(0.28)
      GridPath(path: art.lines, grid: 16)
        .stroke(style: StrokeStyle(lineWidth: Pen.width(size), lineCap: .round, lineJoin: .round))
      GridPath(path: art.dots, grid: 16).fill()
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

struct IconLabel: View {
  let title: String
  let glyph: Glyph
  var body: some View {
    HStack(spacing: Space.tight) {
      AppGlyph(glyph: glyph, size: 14)
      Text(title)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Fixed stroke slots morph coordinates instead of swapping glyph views.
enum ActionMark {
  case arrow, check, play, pause, more, chevron
  var lines: [(CGPoint, CGPoint, Double)] {
    let o = (CGPoint(x: 12, y: 12), CGPoint(x: 12, y: 12), 0.0)
    switch self {
    case .arrow:
      return [
        (.init(x: 4, y: 12), .init(x: 20, y: 12), 1), (.init(x: 14, y: 6), .init(x: 20, y: 12), 1),
        (.init(x: 14, y: 18), .init(x: 20, y: 12), 1),
      ]
    case .check:
      return [
        (.init(x: 5, y: 12), .init(x: 10, y: 17), 1), (.init(x: 10, y: 17), .init(x: 19, y: 7), 1),
        o,
      ]
    case .play:
      return [
        (.init(x: 8, y: 5), .init(x: 8, y: 19), 1), (.init(x: 8, y: 19), .init(x: 20, y: 12), 1),
        (.init(x: 8, y: 5), .init(x: 20, y: 12), 1),
      ]
    case .pause:
      return [
        (.init(x: 8, y: 6), .init(x: 8, y: 18), 1), o, (.init(x: 16, y: 6), .init(x: 16, y: 18), 1),
      ]
    case .more:
      return [
        (.init(x: 5, y: 12), .init(x: 5, y: 12.05), 1),
        (.init(x: 12, y: 12), .init(x: 12, y: 12.05), 1),
        (.init(x: 19, y: 12), .init(x: 19, y: 12.05), 1),
      ]
    case .chevron:
      return [
        o, (.init(x: 9, y: 6), .init(x: 15, y: 12), 1),
        (.init(x: 9, y: 18), .init(x: 15, y: 12), 1),
      ]
    }
  }
}

private struct MorphStroke: Shape {
  var start: CGPoint
  var end: CGPoint
  var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
    get { .init(start.animatableData, end.animatableData) }
    set {
      start.animatableData = newValue.first
      end.animatableData = newValue.second
    }
  }
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: start.x * rect.width / 24, y: start.y * rect.height / 24))
    p.addLine(to: CGPoint(x: end.x * rect.width / 24, y: end.y * rect.height / 24))
    return p
  }
}

struct ActionGlyph: View {
  let mark: ActionMark
  var size: CGFloat = 16
  @MotionReduced private var reduceMotion

  var body: some View {
    ZStack {
      ForEach(0..<3, id: \.self) { i in
        MorphStroke(start: mark.lines[i].0, end: mark.lines[i].1)
          .stroke(
            style: StrokeStyle(lineWidth: Pen.width(size), lineCap: .round, lineJoin: .round)
          )
          .opacity(mark.lines[i].2)
      }
    }
    .frame(width: size, height: size).accessibilityHidden(true)
    .animation(
      reduceMotion ? nil : .smooth(duration: 0.16 * Design.motionScale), value: mark.lines[0].0
    )
    .animation(
      reduceMotion ? nil : .smooth(duration: 0.16 * Design.motionScale), value: mark.lines[2].1)
  }
}

/// The same seven outline vertices become a check; the rear page contracts
/// toward the centre. The two parts stay mounted through interrupted taps.
struct CopyGlyph: View {
  let completed: Bool
  var body: some View {
    ZStack {
      CopyOutline(progress: completed ? 1 : 0)
        .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
      RearPage(progress: completed ? 1 : 0)
        .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        .opacity(completed ? 0 : 1)
    }
  }
}

private struct CopyOutline: Shape {
  var progress: CGFloat
  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }
  func path(in rect: CGRect) -> Path {
    let page: [CGPoint] = [
      .init(x: 9, y: 7), .init(x: 19, y: 7), .init(x: 20, y: 8), .init(x: 20, y: 20),
      .init(x: 8, y: 20), .init(x: 8, y: 8), .init(x: 9, y: 7),
    ]
    let check: [CGPoint] = [
      .init(x: 5, y: 12), .init(x: 10, y: 17), .init(x: 10, y: 17), .init(x: 19, y: 7),
      .init(x: 19, y: 7), .init(x: 19, y: 7), .init(x: 19, y: 7),
    ]
    var path = Path()
    for i in page.indices {
      let x = page[i].x + (check[i].x - page[i].x) * progress
      let y = page[i].y + (check[i].y - page[i].y) * progress
      let point = CGPoint(x: x * rect.width / 24, y: y * rect.height / 24)
      if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
  }
}

private struct RearPage: Shape {
  var progress: CGFloat
  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let points: [CGPoint] = [.init(x: 5, y: 16), .init(x: 5, y: 3), .init(x: 16, y: 3)]
    for i in points.indices {
      let point = CGPoint(
        x: (points[i].x + (12 - points[i].x) * progress) * rect.width / 24,
        y: (points[i].y + (12 - points[i].y) * progress) * rect.height / 24)
      if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
  }
}

/// The same face as the panel, drawn once per mood as a template bitmap.
/// Moods differ by silhouette, so they read without colour: solid, solid with
/// a badge, or an outline.
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
      // bitmap.size already establishes the representation's backing scale.
      context.translateBy(x: 0, y: points)
      context.scaleBy(x: 1, y: -1)
      draw(mood, in: context)
      image.addRepresentation(bitmap)
    }
    image.isTemplate = true
    cache[mood] = image
    return image
  }

  static func draw(_ mood: CompanionMood, in context: CGContext) {
    var pose = mood.pose
    // Upright and with heavier marks: 20 points leaves no room for nuance.
    pose[.lean] = 0
    pose[.lift] = 0
    if mood == .working || mood == .trouble {
      for part in [MaxPose.Part.leftWidth, .rightWidth, .middle] { pose[part] *= 1.25 }
      for part in [MaxPose.Part.leftHeight, .rightHeight] { pose[part] *= 1.2 }
    } else if mood == .resting {
      pose[.leftHeight] = 1.6
    }
    if mood == .trouble { pose[.badge] = 1 }
    let rect = CGRect(x: 0, y: 0, width: points, height: points)
    context.setFillColor(NSColor.black.cgColor)
    context.setStrokeColor(NSColor.black.cgColor)
    if mood == .working || mood == .resting {
      context.addPath(MaxFace.silhouette(pose, in: rect.insetBy(dx: 0.7, dy: 0.7)))
      context.setLineWidth(1.4)
      context.setLineJoin(.round)
      context.strokePath()
      context.addPath(MaxFace.eyes(pose, in: rect))
      context.addPath(MaxFace.sparkle(pose, in: rect))
      context.fillPath()
    } else {
      context.addPath(MaxFace.path(pose, in: rect))
      context.fillPath(using: .evenOdd)
    }
    if let badge = MaxFace.badge(pose, in: rect) {
      context.addPath(badge)
      context.fillPath()
    }
  }
}
