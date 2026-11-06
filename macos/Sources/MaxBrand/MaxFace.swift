import CoreGraphics
import Foundation

/// A face is one row of numbers on the bubble's 24-unit grid. Every pose has
/// the same parts, so any face reaches any other without swapping drawings.
/// At rest the bubble is plain. When it is busy it shows the product's own
/// typing dots, which are parked at zero size until then.
public struct MaxPose: Equatable, Sendable {
  public enum Part: Int, CaseIterable, Sendable {
    case lean, lift, stretchX, stretchY
    case leftX, leftY, leftWidth, leftHeight
    case rightX, rightY, rightWidth, rightHeight
    case middle, middleLift, badge, dim
  }

  public var values: [CGFloat]

  public subscript(part: Part) -> CGFloat {
    get { values[part.rawValue] }
    set { values[part.rawValue] = newValue }
  }

  public init(
    left: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat),
    right: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat),
    lean: CGFloat = 0, lift: CGFloat = 0, middle: CGFloat = 0, badge: CGFloat = 0,
    dim: CGFloat = 0
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
    self[.badge] = badge
    self[.dim] = dim
  }

  private static let none: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) = (12, 11, 0, 0)

  /// The rest pose: a plain bubble, leaning in a little.
  public static let rest = MaxPose(left: none, right: none, lean: -3)
  /// A badge: a setup step is waiting for the person.
  public static let needsYou = MaxPose(left: none, right: none, lean: -5, badge: 1)
  /// Three dots: a typing indicator.
  public static let working = MaxPose(
    left: (8.2, 11, 2.7, 2.7), right: (15.8, 11, 2.7, 2.7), middle: 2.7)
  /// A plain exclamation mark. No sad or angry face.
  public static let trouble = MaxPose(
    left: (12, 8.8, 2.7, 6.2), right: (12, 14.9, 2.7, 2.7))
  /// A dash; the bubble droops and dims: turned off.
  public static let asleep = MaxPose(
    left: (12, 11.8, 5.2, 1.0), right: (12, 11.8, 0, 0), lean: 4, lift: 0.4, dim: 1)
  /// A deeper lean in answer to a click.
  public static let wink = MaxPose(left: none, right: none, lean: -8)
}

/// The service's state as the companion wears it. Every mood-to-face choice,
/// in the panel and in the menu bar, is made here.
public enum CompanionMood: Hashable, CaseIterable, Sendable {
  case ready, needsYou, working, resting, trouble

  public var pose: MaxPose {
    switch self {
    case .ready: .rest
    case .needsYou: .needsYou
    case .working: .working
    case .resting: .asleep
    case .trouble: .trouble
    }
  }

  /// The menu bar's version: upright and with heavier marks, because 20
  /// points leaves no room for nuance. Trouble gains a badge so it reads
  /// without colour.
  public var menuBarPose: MaxPose {
    var pose = pose
    pose[.lean] = 0
    pose[.lift] = 0
    switch self {
    case .working, .trouble:
      for part in [MaxPose.Part.leftWidth, .rightWidth, .middle] { pose[part] *= 1.25 }
      for part in [MaxPose.Part.leftHeight, .rightHeight] { pose[part] *= 1.2 }
      if self == .trouble { pose[.badge] = 1 }
    case .resting:
      pose[.leftHeight] = 1.6
    case .ready, .needsYou:
      break
    }
    return pose
  }

  /// In the menu bar, working and resting are outlines; the others are solid
  /// with their marks cut out.
  public var menuBarOutlined: Bool { self == .working || self == .resting }
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

  /// The round bubble is built once: its corner rounding is too costly to
  /// redo on every frame of an animation. CGPath is immutable.
  nonisolated(unsafe) private static let roundBody = MessageMark.round(
    in: CGRect(x: 0, y: 0, width: 24, height: 24))

  /// The round bubble, with a soft-edged room cut for the badge so it sits in
  /// front on any background, including a monochrome menu bar.
  public static func silhouette(_ pose: MaxPose, in rect: CGRect) -> CGPath {
    var body = roundBody
    if pose[.badge] > 0.02 {
      body = MessageMark.softened(
        body.subtracting(circle(badgeCentre, (badgeRadius + badgeGap) * pose[.badge])), by: 0.6)
    }
    var matrix = transform(pose, in: rect)
    return body.copy(using: &matrix) ?? body
  }

  public static func eyes(_ pose: MaxPose, in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    path.addPath(
      eye(x: pose[.leftX], y: pose[.leftY], width: pose[.leftWidth], height: pose[.leftHeight]))
    path.addPath(
      eye(
        x: pose[.rightX], y: pose[.rightY], width: pose[.rightWidth], height: pose[.rightHeight]))
    if pose[.middle] > 0.05 {
      let centre = CGPoint(
        x: (pose[.leftX] + pose[.rightX]) / 2,
        y: (pose[.leftY] + pose[.rightY]) / 2 + pose[.middleLift])
      path.addPath(circle(centre, pose[.middle] / 2))
    }
    var matrix = transform(pose, in: rect)
    return path.copy(using: &matrix) ?? path
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

  private static func eye(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGPath {
    guard width > 0.05, height > 0.05 else { return CGMutablePath() }
    let corner = min(width, height) * 0.499
    return CGPath(
      roundedRect: CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height),
      cornerWidth: corner, cornerHeight: corner, transform: nil)
  }
}
