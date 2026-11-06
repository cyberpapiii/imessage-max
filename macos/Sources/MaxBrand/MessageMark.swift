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

  public static func round(in rect: CGRect) -> CGPath {
    let wedge = CGMutablePath()
    wedge.addLines(between: [
      CGPoint(x: 3.6, y: 13.2), CGPoint(x: 11.4, y: 19.0), CGPoint(x: 3.0, y: 21.6),
    ])
    wedge.closeSubpath()
    let path = filled(
      CGPath(ellipseIn: CGRect(x: 2.5, y: 1.5, width: 19, height: 19), transform: nil)
        .union(softened(wedge, by: 1.6)), by: 1.0)
    var transform = CGAffineTransform(
      a: rect.width / 24, b: 0, c: 0, d: rect.height / 24, tx: rect.minX, ty: rect.minY)
    return path.copy(using: &transform)!
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
