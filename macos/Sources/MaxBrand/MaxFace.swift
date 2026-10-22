import CoreGraphics
import Foundation

/// A face is one row of numbers on the bubble's 24-unit grid. Every pose has
/// the same parts, so any face reaches any other without swapping drawings.
/// At rest the bubble carries one sparkle. When it is busy the sparkle gives
/// way to the product's own typing dots, which are parked at zero size until
/// then.
public struct MaxPose: Equatable, Sendable {
  public enum Part: Int, CaseIterable, Sendable {
    case lean, lift, stretchX, stretchY
    case leftX, leftY, leftWidth, leftHeight
    case rightX, rightY, rightWidth, rightHeight
    case middle, middleLift, arch, badge, dim, spark, spin, blink
  }

  public var values: [CGFloat]

  public subscript(part: Part) -> CGFloat {
    get { values[part.rawValue] }
    set { values[part.rawValue] = newValue }
  }

  public init(
    left: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat),
    right: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat),
    lean: CGFloat = 0, lift: CGFloat = 0, middle: CGFloat = 0, arch: CGFloat = 0,
    badge: CGFloat = 0, dim: CGFloat = 0, spark: CGFloat = 0, spin: CGFloat = 0
  ) {
    values = Array(repeating: 0, count: Part.allCases.count)
    self[.lean] = lean
    self[.lift] = lift
    self[.stretchX] = 1
    self[.stretchY] = 1
    self[.leftX] = left.x
    self[.leftY] = left.y
    self[.leftWidth] = left.width
    self[.leftHeight] = left.height
    self[.rightX] = right.x
    self[.rightY] = right.y
    self[.rightWidth] = right.width
    self[.rightHeight] = right.height
    self[.middle] = middle
    self[.arch] = arch
    self[.badge] = badge
    self[.dim] = dim
    self[.spark] = spark
    self[.spin] = spin
  }

  private static let none: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) = (12, 11, 0, 0)

  /// The rest pose is the app icon: one sparkle in a bubble.
  public static let rest = MaxPose(left: none, right: none, lean: -3, spark: 1)
  /// A larger sparkle and a badge: a setup step is waiting for the person.
  public static let needsYou = MaxPose(left: none, right: none, lean: -5, badge: 1, spark: 1.12)
  /// The sparkle gives way to three dots: a typing indicator.
  public static let working = MaxPose(
    left: (8.2, 11, 2.7, 2.7), right: (15.8, 11, 2.7, 2.7), middle: 2.7)
  /// A plain exclamation mark. No sad or angry face.
  public static let trouble = MaxPose(
    left: (12, 8.8, 2.7, 6.2), right: (12, 14.9, 2.7, 2.7))
  /// The sparkle closes to a dash; the bubble droops and dims: turned off.
  public static let asleep = MaxPose(
    left: (12, 11.8, 5.2, 1.0), right: (12, 11.8, 0, 0), lean: 4, lift: 0.4, dim: 1)
  /// The sparkle swells and turns. Used only for rare good news.
  public static let happy = MaxPose(left: none, right: none, lean: -3, spark: 1.28, spin: 90)
  /// A quarter turn in answer to a click.
  public static let wink = MaxPose(left: none, right: none, lean: -8, spark: 1, spin: 90)
}

public enum MaxFace {
  private static let pivot = CGPoint(x: 12, y: 20)
  private static let badgeCentre = CGPoint(x: 19.7, y: 4.3)
  private static let badgeRadius: CGFloat = 2.8
  private static let badgeGap: CGFloat = 1.2

  /// Grid space to `rect`, with the pose's lean, squash, and lift applied
  /// about the bubble's base so a squash stays grounded.
  public static func transform(_ pose: MaxPose, in rect: CGRect) -> CGAffineTransform {
    CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
      .concatenating(CGAffineTransform(scaleX: pose[.stretchX], y: pose[.stretchY]))
      .concatenating(CGAffineTransform(rotationAngle: pose[.lean] * .pi / 180))
      .concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y + pose[.lift]))
      .concatenating(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
      .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
  }

  /// The bubble, with room cut for the badge so it sits in front on any
  /// background, including a monochrome menu bar.
  public static func silhouette(_ pose: MaxPose, in rect: CGRect) -> CGPath {
    var body = MessageMark.body(in: CGRect(x: 0, y: 0, width: 24, height: 24))
    if pose[.badge] > 0.02 {
      body = body.subtracting(circle(badgeCentre, (badgeRadius + badgeGap) * pose[.badge]))
    }
    var matrix = transform(pose, in: rect)
    return body.copy(using: &matrix) ?? body
  }

  public static func eyes(_ pose: MaxPose, in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    path.addPath(
      eye(
        x: pose[.leftX], y: pose[.leftY], width: pose[.leftWidth], height: pose[.leftHeight],
        arch: pose[.arch]))
    path.addPath(
      eye(
        x: pose[.rightX], y: pose[.rightY], width: pose[.rightWidth], height: pose[.rightHeight],
        arch: pose[.arch]))
    if pose[.middle] > 0.05 {
      let centre = CGPoint(
        x: (pose[.leftX] + pose[.rightX]) / 2,
        y: (pose[.leftY] + pose[.rightY]) / 2 + pose[.middleLift])
      path.addPath(circle(centre, pose[.middle] / 2))
    }
    var matrix = transform(pose, in: rect)
    return path.copy(using: &matrix) ?? path
  }

  /// Bubble, sparkle, and dots as one even-odd path: the marks are holes,
  /// so they take the colour of whatever is behind the bubble.
  public static func path(_ pose: MaxPose, in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    path.addPath(silhouette(pose, in: rect))
    path.addPath(eyes(pose, in: rect))
    path.addPath(sparkle(pose, in: rect))
    return path
  }

  /// The sparkle at the bubble's centre. A blink flattens it; `spin` turns it.
  public static func sparkle(_ pose: MaxPose, in rect: CGRect) -> CGPath {
    guard pose[.spark] > 0.02 else { return CGMutablePath() }
    let shape = star(.zero, 5.6 * pose[.spark])
    var place = CGAffineTransform(rotationAngle: pose[.spin] * .pi / 180)
      .concatenating(CGAffineTransform(scaleX: 1, y: max(1 - 0.88 * pose[.blink], 0.05)))
      .concatenating(CGAffineTransform(translationX: 12, y: 11))
      .concatenating(transform(pose, in: rect))
    return shape.copy(using: &place) ?? shape
  }

  private static func star(_ centre: CGPoint, _ radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let pinch = radius * 0.14
    let points: [(CGFloat, CGFloat)] = [(0, -1), (1, 0), (0, 1), (-1, 0)]
    path.move(to: CGPoint(x: centre.x, y: centre.y - radius))
    for index in 1...4 {
      let (fromX, fromY) = points[index - 1]
      let (toX, toY) = points[index % 4]
      path.addQuadCurve(
        to: CGPoint(x: centre.x + toX * radius, y: centre.y + toY * radius),
        control: CGPoint(
          x: centre.x + (fromX + toX) * pinch, y: centre.y + (fromY + toY) * pinch))
    }
    path.closeSubpath()
    return path
  }

  public static func badge(_ pose: MaxPose, in rect: CGRect) -> CGPath? {
    guard pose[.badge] > 0.02 else { return nil }
    var matrix = transform(pose, in: rect)
    return circle(badgeCentre, badgeRadius * pose[.badge]).copy(using: &matrix)
  }

  private static func circle(_ centre: CGPoint, _ radius: CGFloat) -> CGPath {
    CGPath(
      ellipseIn: CGRect(
        x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2),
      transform: nil)
  }

  private static func eye(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, arch: CGFloat)
    -> CGPath
  {
    guard width > 0.05, height > 0.05 else { return CGMutablePath() }
    let corner = min(width, height) * 0.499
    let pill = CGPath(
      roundedRect: CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height),
      cornerWidth: corner, cornerHeight: corner, transform: nil)
    guard arch > 0.02 else { return pill }
    let cheek = width * 0.95
    return pill.subtracting(
      circle(CGPoint(x: x, y: y + height / 2 + cheek - arch * height * 0.62), cheek))
  }
}
