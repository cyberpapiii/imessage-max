import MaxBrand
import SwiftUI

// Values are this product's tokens, not timings or colours attributed to Benji.
enum Design {
  static let width: CGFloat = 340
  static let inset: CGFloat = 16
  /// The tallest the panel grows; shorter screens cap it lower.
  static let maximumPanelHeight: CGFloat = 720

  // One action colour. Status roles are separate and never used for buttons.
  static let blue = Color(
    red: MessageMark.blue.red, green: MessageMark.blue.green, blue: MessageMark.blue.blue)
  static let ready = adaptive(light: 0x237446, dark: 0x79CF9E)
  static let attention = adaptive(light: 0x985410, dark: 0xF0BA76)
  static let running = adaptive(light: 0x2F9E5B, dark: 0x3DB56E)
  static let badge = Color(red: 0.96, green: 0.60, blue: 0.18)
  static let canvas = adaptive(light: 0xF8F8F6, dark: 0x232527)
  static let card = adaptive(light: 0xFFFFFF, dark: 0x2D3033)
  static let well = adaptive(light: 0xECEDEA, dark: 0x383C40)
  static let track = adaptive(light: 0xD3D6D2, dark: 0x4A4F54)
  static let muted = adaptive(light: 0x626763, dark: 0xB8BCB9)
  static let wash = 0.11

  private static func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(
          srgbRed: Double((value >> 16) & 255) / 255,
          green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
      })
  }
}

enum Space {
  static let hairline: CGFloat = 2
  static let rowGap: CGFloat = 4
  static let tight: CGFloat = 6
  static let snug: CGFloat = 10
  static let regular: CGFloat = 14
}

enum Radius {
  static let card: CGFloat = 10
  static let control: CGFloat = 7
}

/// Four type roles. Nothing in the panel is smaller than 12 points.
extension Font {
  static let maxTitle = Font.system(size: 15, weight: .semibold)
  static let maxLine = Font.system(size: 13)
  static let maxStrong = Font.system(size: 13, weight: .medium)
  static let maxSmall = Font.system(size: 12)
  static let maxCode = Font.system(size: 12, design: .monospaced)
}

/// Per-process motion overrides, injected at the panel's root. Design checks
/// use them to slow everything down or force Reduce Motion without touching
/// the Mac's own setting.
struct MotionSettings: Equatable {
  var scale = 1.0
  var reduce = false
}

extension EnvironmentValues {
  @Entry var motionSettings = MotionSettings()
}

/// The panel's animations at the injected speed. Frequency sets speed:
/// presses and hovers are quickest, a page change is the slowest thing the
/// panel does.
struct Motion {
  enum Kind { case hover, press, toggle, swap, step, glide, morph }

  let reduced: Bool
  let scale: Double

  /// The animation for `kind`, or nil when motion is reduced.
  subscript(kind: Kind) -> Animation? {
    guard !reduced else { return nil }
    return switch kind {
    case .hover: .easeOut(duration: 0.10 * scale)
    case .press: .snappy(duration: 0.15 * scale)
    case .toggle: .snappy(duration: 0.20 * scale)
    case .swap: .snappy(duration: 0.25 * scale)
    case .step: .snappy(duration: 0.32 * scale)
    case .glide: .smooth(duration: 0.25 * scale)
    case .morph: .smooth(duration: 0.16 * scale)
    }
  }
}

/// Reduce Motion from the system or the injected settings, with the
/// injected speed.
@propertyWrapper
struct PanelMotion: DynamicProperty {
  @Environment(\.accessibilityReduceMotion) private var system
  @Environment(\.motionSettings) private var settings
  var wrappedValue: Motion { Motion(reduced: system || settings.reduce, scale: settings.scale) }
}

// MARK: - Face

/// Moves the face with one spring per part, stepped by hand so a new target
/// bends the motion already under way. Nothing runs while the face is at rest.
@MainActor @Observable
final class FaceEngine {
  private(set) var running = false
  private(set) var revision = 0
  @ObservationIgnored private var pose = MaxPose.rest
  @ObservationIgnored private var goal = MaxPose.rest
  @ObservationIgnored private var speed = [CGFloat](
    repeating: 0, count: MaxPose.Part.allCases.count)
  @ObservationIgnored private var last: Date?
  @ObservationIgnored private var settled = true
  @ObservationIgnored private var mood = CompanionMood.ready
  @ObservationIgnored private var sparks: Date?
  @ObservationIgnored private var dots: Date?
  @ObservationIgnored private var sheen: Date?
  @ObservationIgnored private var pending: [DispatchWorkItem] = []
  /// Slows every timing; design checks set it above 1.
  @ObservationIgnored var scale = 1.0

  private var sparkTime: Double { 0.6 * scale }
  private var sheenTime: Double { 0.9 * scale }

  func show(_ mood: CompanionMood, animated: Bool) {
    cancel()
    self.mood = mood
    dots = mood == .working && animated ? .now : nil
    guard animated else {
      place(mood.pose)
      return
    }
    goal = mood.pose
    wake()
  }

  func cheer(animated: Bool) {
    cancel()
    let mood = mood
    guard animated else {
      place(.rest)
      after(1.6) { [weak self] in self?.place(mood.pose) }
      return
    }
    goal = .rest
    kick(1.3)
    sparks = .now
    sheen = .now
    wake()
    after(1.6) { [weak self] in
      self?.goal = mood.pose
      self?.wake()
    }
  }

  func poke(animated: Bool) {
    guard animated, mood == .ready || mood == .needsYou, pending.isEmpty else { return }
    goal = .wink
    kick(0.45)
    sheen = .now
    wake()
    after(0.5) { [weak self] in
      guard let self else { return }
      goal = mood.pose
      wake()
    }
  }

  /// The panel closed: drop every timer and land on the current face.
  func sleep() {
    cancel()
    dots = nil
    place(mood.pose)
  }

  /// Advances the springs to `date` and returns what to draw.
  func frame(at date: Date) -> (pose: MaxPose, sparks: CGFloat?, sheen: CGFloat?) {
    if running {
      let elapsed = min(last.map { date.timeIntervalSince($0) } ?? 0, 1.0 / 30)
      last = date
      var moving = false
      for _ in 0..<2 {
        let dt = CGFloat(elapsed / 2 / scale)
        for part in MaxPose.Part.allCases {
          let (stiffness, damping) = Self.spring(part)
          let index = part.rawValue
          let gap = goal.values[index] - pose.values[index]
          speed[index] += (stiffness * gap - damping * speed[index]) * dt
          pose.values[index] += speed[index] * dt
          if abs(speed[index]) > 0.02 || abs(gap) > 0.005 { moving = true }
        }
      }
      if let start = sparks, date.timeIntervalSince(start) > sparkTime { sparks = nil }
      if let start = sheen, date.timeIntervalSince(start) > sheenTime { sheen = nil }
      settled = !moving && sparks == nil && dots == nil && sheen == nil
      if settled {
        pose = goal
        speed = speed.map { _ in 0 }
      }
    }
    var drawn = pose
    if let dots {
      // The three dots hop in turn, 0.4 s each, like a typing indicator.
      let time = date.timeIntervalSince(dots) / scale
      func hop(_ place: Double) -> CGFloat {
        let local = (time - 0.4 * place).truncatingRemainder(dividingBy: 1.2)
        return local >= 0 && local < 0.4 ? -1.5 * sin(.pi * local / 0.4) : 0
      }
      let (left, middle, right) = (hop(0), hop(1), hop(2))
      drawn[.leftY] += left
      drawn[.rightY] += right
      drawn[.middleLift] += middle - (left + right) / 2
    }
    return (
      drawn, sparks.map { CGFloat(date.timeIntervalSince($0) / sparkTime) },
      sheen.map { CGFloat(date.timeIntervalSince($0) / sheenTime) }
    )
  }

  /// Called after a frame is on screen; pauses the timeline once still.
  func rest() {
    guard running, settled else { return }
    running = false
    last = nil
  }

  private static func spring(_ part: MaxPose.Part) -> (CGFloat, CGFloat) {
    switch part {
    case .lean: (210, 15)
    case .lift: (300, 13)
    case .stretchX, .stretchY: (300, 16)
    default: (190, 23)
    }
  }

  private func kick(_ strength: CGFloat) {
    speed[MaxPose.Part.lift.rawValue] -= 34 * strength
    speed[MaxPose.Part.stretchY.rawValue] += 2.4 * strength
    speed[MaxPose.Part.stretchX.rawValue] -= 2.0 * strength
  }

  private func place(_ pose: MaxPose) {
    self.pose = pose
    goal = pose
    speed = speed.map { _ in 0 }
    sparks = nil
    sheen = nil
    settled = true
    running = false
    last = nil
    revision += 1
  }

  private func wake() {
    settled = false
    if !running { running = true }
  }

  private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
    var item: DispatchWorkItem?
    item = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.pending.removeAll { $0 === item }
        work()
      }
    }
    pending.append(item!)
    DispatchQueue.main.asyncAfter(
      deadline: .now() + seconds * scale, execute: item!)
  }

  private func cancel() {
    pending.forEach { $0.cancel() }
    pending.removeAll()
  }
}

/// The product's mark, alive: a round speech bubble. Its expression is the
/// service's state; it is decoration to assistive tech,
/// which reads the title beside it instead.
struct MaxFaceView: View {
  let mood: CompanionMood
  let celebration: Int
  var size: CGFloat = 48
  /// False while the panel is closed, so nothing animates out of sight.
  var awake = true
  @State private var engine = FaceEngine()
  @PanelMotion private var motion

  var body: some View {
    let margin = size * 0.3
    TimelineView(.animation(paused: !engine.running)) { timeline in
      let _ = engine.revision
      let frame = engine.frame(at: timeline.date)
      Canvas { context, _ in
        let rect = CGRect(x: margin, y: margin, width: size, height: size)
        let dim = frame.pose[.dim]
        func tone(_ blue: (Double, Double, Double), _ grey: Double) -> Color {
          Color(
            red: blue.0 + (grey - blue.0) * dim, green: blue.1 + (grey - blue.1) * dim,
            blue: blue.2 + (grey - blue.2) * dim)
        }
        let mark = MessageMark.blue
        let body = Path(MaxFace.silhouette(frame.pose, in: rect))
        // Lit from above and lifted off the panel by a soft shadow, like the
        // app icon.
        context.drawLayer { layer in
          layer.addFilter(
            .shadow(
              color: tone((0.05, 0.25, 0.70), 0.2).opacity(0.38), radius: size * 0.07,
              y: size * 0.045))
          layer.fill(
            body,
            with: .linearGradient(
              Gradient(colors: [
                tone((0.36, 0.74, 1.0), 0.70), tone((mark.red, mark.green, mark.blue), 0.56),
                tone((0.04, 0.31, 0.85), 0.46),
              ]),
              startPoint: CGPoint(x: rect.midX, y: rect.minY),
              endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }
        // The shimmer: a faint light on the shoulder, and a band of light
        // that crosses the bubble on a click or good news.
        let shine = 1 - dim
        context.drawLayer { layer in
          layer.clip(to: body)
          layer.fill(
            body,
            with: .radialGradient(
              Gradient(colors: [.white.opacity(0.30 * shine), .white.opacity(0)]),
              center: CGPoint(x: rect.midX, y: rect.minY),
              startRadius: 0, endRadius: size * 0.6))
          if let progress = frame.sheen {
            let place = -0.35 + 1.7 * (1 - pow(1 - min(progress, 1), 2))
            func point(_ along: CGFloat) -> CGPoint {
              CGPoint(x: rect.minX + size * along, y: rect.minY + size * along * 0.55)
            }
            layer.fill(
              body,
              with: .linearGradient(
                Gradient(colors: [.white.opacity(0), .white.opacity(0.26), .white.opacity(0)]),
                startPoint: point(place - 0.2), endPoint: point(place + 0.2)))
          }
        }
        context.fill(Path(MaxFace.eyes(frame.pose, in: rect)), with: .color(.white))
        if let badge = MaxFace.badge(frame.pose, in: rect) {
          context.fill(Path(badge), with: .color(Design.badge))
        }
        if let progress = frame.sparks {
          // Five short bars fan over 120 degrees above the bubble and fade.
          let centre = CGPoint(x: rect.midX, y: rect.minY + size * 0.42)
          let ease = 1 - pow(1 - min(progress, 1), 3)
          for index in 0..<5 {
            let angle = (-150 + 30 * Double(index)) * .pi / 180
            let near = size * (0.50 + 0.16 * ease)
            let far = near + size * 0.10 * (1 - ease * 0.6)
            var bar = Path()
            bar.move(
              to: CGPoint(x: centre.x + cos(angle) * near, y: centre.y + sin(angle) * near))
            bar.addLine(
              to: CGPoint(x: centre.x + cos(angle) * far, y: centre.y + sin(angle) * far))
            context.stroke(
              bar, with: .color(Design.badge.opacity(1 - Double(ease))),
              style: StrokeStyle(lineWidth: max(1.6, size / 26), lineCap: .round))
          }
        }
      }
      .onChange(of: timeline.date) { engine.rest() }
    }
    .frame(width: size + margin * 2, height: size + margin * 2)
    .padding(-margin)
    .frame(width: size, height: size)
    .contentShape(Rectangle())
    .onTapGesture { engine.poke(animated: awake && !motion.reduced) }
    .onAppear {
      engine.scale = motion.scale
      engine.show(mood, animated: false)
    }
    .onChange(of: mood) { engine.show(mood, animated: awake && !motion.reduced) }
    .onChange(of: celebration) { if awake { engine.cheer(animated: !motion.reduced) } }
    .onChange(of: awake) {
      if awake { engine.show(mood, animated: !motion.reduced) } else { engine.sleep() }
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Controls

/// A drawn switch: the knob slides, the track changes role colour.
struct MaxSwitchStyle: ToggleStyle {
  @Environment(\.isEnabled) private var enabled
  @PanelMotion private var motion

  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      Capsule()
        .fill(configuration.isOn ? Design.running : Design.track)
        .frame(width: 36, height: 20)
        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
          Circle().fill(.white)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            .frame(width: 16, height: 16).padding(2)
        }
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .opacity(enabled ? 1 : 0.5)
    .animation(motion[.toggle], value: configuration.isOn)
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }
    }
  }
}

struct MaxButtonStyle: ButtonStyle {
  var primary = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.colorSchemeContrast) private var contrast
  @PanelMotion private var motion
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
    configuration.label
      .font(.system(size: 13, weight: primary ? .semibold : .medium))
      .padding(.horizontal, primary ? Space.regular : Space.snug)
      .padding(.vertical, primary ? 9 : 6)
      .foregroundStyle(primary ? Color.white : Color.primary)
      .background {
        shape.fill(primary ? Design.blue : Design.well)
          .overlay {
            shape.fill(
              primary
                ? Color.black.opacity(hovering ? 0.07 : 0)
                : Color.primary.opacity(hovering ? 0.05 : 0))
          }
      }
      .overlay {
        if contrast == .increased {
          shape.strokeBorder(primary ? Color.white.opacity(0.4) : Color.primary.opacity(0.35))
        }
      }
      .contentShape(shape)
      .opacity(enabled ? 1 : 0.45)
      .scaleEffect(configuration.isPressed && !motion.reduced ? 0.98 : 1)
      .onHover { hovering = $0 }
      .animation(motion[.hover], value: hovering)
      .animation(motion[.press], value: configuration.isPressed)
  }
}

/// A grouped surface. A wash colour marks the one card that needs the person.
struct Card<Content: View>: View {
  var wash: Color?
  @ViewBuilder var content: Content
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
    VStack(alignment: .leading, spacing: Space.snug) { content }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Space.regular)
      .background(wash.map { $0.opacity(Design.wash) } ?? Design.card, in: shape)
      .overlay {
        if contrast == .increased { shape.strokeBorder(Color.primary.opacity(0.35)) }
      }
  }
}

struct StatusLine: View {
  let glyph: Glyph
  let title: String
  let detail: String
  let good: Bool
  let attention: Bool
  @PanelMotion private var motion

  private var ink: Color { good ? Design.ready : (attention ? Design.attention : Design.muted) }
  var body: some View {
    HStack(spacing: Space.snug) {
      AppGlyph(glyph: glyph).foregroundStyle(Design.muted)
      Text(title).font(.maxLine)
      Spacer(minLength: Space.snug)
      Text(detail).font(.maxSmall).foregroundStyle(ink).contentTransition(.interpolate)
      ActionGlyph(mark: good ? .check : (attention ? .more : .pause), size: 12)
        .foregroundStyle(ink)
    }
    .frame(minHeight: 24)
    .animation(motion[.swap], value: detail)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title): \(detail)")
  }
}

/// A row that leads to another page inside the same panel.
struct NavRow: View {
  let title: String
  let glyph: Glyph
  let action: () -> Void
  @State private var hovering = false
  @PanelMotion private var motion

  var body: some View {
    Button(action: action) {
      HStack(spacing: Space.snug) {
        AppGlyph(glyph: glyph).foregroundStyle(Design.muted)
        Text(title).font(.maxLine)
        Spacer()
        ActionGlyph(mark: .chevron, size: 12).foregroundStyle(Design.muted)
      }
      .padding(.horizontal, Space.snug).frame(minHeight: 32)
      .contentShape(RoundedRectangle(cornerRadius: Radius.control))
      .background(
        hovering ? Design.well : .clear,
        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(motion[.hover], value: hovering)
    .accessibilityHint("Show \(title.lowercased())")
  }
}

struct IconButton: View {
  let glyph: Glyph
  let label: String
  let action: () -> Void
  @State private var hovering = false
  @PanelMotion private var motion

  var body: some View {
    Button(action: action) {
      AppGlyph(glyph: glyph, size: 14).foregroundStyle(Design.muted)
        .frame(width: 24, height: 24)
        .background(hovering ? Design.well : .clear, in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(motion[.hover], value: hovering)
    .help(label).accessibilityLabel(label)
  }
}

struct CopyButton: View {
  let title: String
  let action: () -> Void
  @State private var copied = false
  @PanelMotion private var motion

  var body: some View {
    Button {
      action()
      copied = true
    } label: {
      HStack(spacing: Space.tight) {
        CopyGlyph(completed: copied).frame(width: 14, height: 14).accessibilityHidden(true)
        Text(title)
      }
    }
    .buttonStyle(MaxButtonStyle())
    .animation(motion[.swap], value: copied)
    .accessibilityLabel(copied ? "\(title), copied" : title)
  }
}

/// A short acknowledgement that floats over the panel and leaves on its own.
struct Toast: View {
  let text: String
  let good: Bool

  var body: some View {
    HStack(spacing: Space.tight) {
      AppGlyph(glyph: good ? .check : .details, size: 14)
        .foregroundStyle(good ? Design.ready : Design.muted)
      Text(text).font(.maxSmall).fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, Space.regular).padding(.vertical, 8)
    .floatingSurface()
    .padding(.horizontal, Design.inset)
    .accessibilityHidden(true)
  }
}

extension View {
  /// Glass is kept for things that float; older systems get a material.
  @ViewBuilder fileprivate func floatingSurface() -> some View {
    #if compiler(>=6.2)
      if #available(macOS 26.0, *) {
        glassEffect(.regular, in: Capsule())
      } else {
        background(.regularMaterial, in: Capsule())
          .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
      }
    #else
      background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    #endif
  }
}
