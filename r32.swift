import CoreGraphics

/// Speech-bubble anatomy shared by the app tile, panel, and menu bar.
/// All coordinates live on one 24-unit grid; small chrome has separate detail.
public enum MessageMark {
  public static let blue = (red: 0.13, green: 0.43, blue: 0.91)

  /// A round bubble with a tail swept to the lower left, in the manner of
  /// a chat bubble. Drawn here from an ellipse and three curves.
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
}
