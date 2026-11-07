import CoreGraphics

public enum MessageMark {
  public static let blue = (red: 0.13, green: 0.43, blue: 0.91)

  public static func body(in rect: CGRect) -> CGPath {
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 4.6, y: 15.6))
    tail.addCurve(
      to: CGPoint(x: 2.9, y: 21.9), control1: CGPoint(x: 5.5, y: 18.4),
      control2: CGPoint(x: 4.5, y: 20.8))
    tail.addCurve(
      to: CGPoint(x: 10.4, y: 19.4), control1: CGPoint(x: 5.9, y: 22.3),
      control2: CGPoint(x: 8.6, y: 21.2))
    tail.closeSubpath()
    let path = CGPath(ellipseIn: CGRect(x: 2, y: 2.4, width: 20, height: 17.6), transform: nil)
      .union(tail)
    var transform = CGAffineTransform(
      a: rect.width / 24, b: 0, c: 0, d: rect.height / 24, tx: rect.minX, ty: rect.minY)
    return path.copy(using: &transform)!
  }

  /// One outline, so the tail leaves and rejoins the circle along its tangent
  /// on both sides instead of meeting it at a corner.
  public static func round(in rect: CGRect) -> CGPath {
    let centre = CGPoint(x: 12, y: 11)
    let radius: CGFloat = 9.5
    func onCircle(_ degrees: CGFloat) -> (point: CGPoint, heading: CGPoint) {
      let angle = degrees * .pi / 180
      return (
        CGPoint(x: centre.x - radius * cos(angle), y: centre.y + radius * sin(angle)),
        CGPoint(x: sin(angle), y: cos(angle))
      )
    }
    let outer = onCircle(32)
    let inner = onCircle(70)
    let tip = CGPoint(x: 2.6, y: 21.7)
    let path = CGMutablePath()
    path.move(to: inner.point)
    path.addArc(
      center: centre, radius: radius, startAngle: .pi * (180 - 70) / 180,
      endAngle: .pi * (180 - 32 - 360) / 180, clockwise: true)
    path.addCurve(
      to: tip,
      control1: CGPoint(x: outer.point.x + outer.heading.x * 2.4, y: outer.point.y + outer.heading.y * 2.4),
      control2: CGPoint(x: tip.x + 0.8, y: tip.y - 0.8))
    path.addCurve(
      to: inner.point, control1: CGPoint(x: tip.x + 2.6, y: tip.y - 0.39),
      control2: CGPoint(x: inner.point.x - inner.heading.x, y: inner.point.y - inner.heading.y))
    path.closeSubpath()
    var transform = CGAffineTransform(
      a: rect.width / 24, b: 0, c: 0, d: rect.height / 24, tx: rect.minX, ty: rect.minY)
    return softened(path, by: 0.5).copy(using: &transform)!
  }

  public static func softened(_ path: CGPath, by radius: CGFloat) -> CGPath {
    let shrunk = path.subtracting(rounded(path, width: 2 * radius))
    return filled(shrunk.union(rounded(shrunk, width: 2 * radius)), by: radius)
  }

  static func filled(_ path: CGPath, by radius: CGFloat) -> CGPath {
    let grown = path.union(rounded(path, width: 2 * radius))
    return grown.subtracting(rounded(grown, width: 2 * radius))
  }

  public static func rounded(_ path: CGPath, width: CGFloat) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
  }
}
