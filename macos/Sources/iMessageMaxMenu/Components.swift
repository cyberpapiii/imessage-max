import MaxBrand
import SwiftUI

// Values are this product's tokens, not timings or colours attributed to Benji.
enum Design {
  static let width: CGFloat = 340
  static let inset: CGFloat = 16
  static let reduceMotionOverride = CommandLine.arguments.contains("--design-reduce-motion")
  static let motionScale = CommandLine.arguments.contains("--design-slow-motion") ? 4.0 : 1.0

  // One action colour. Status roles are separate and never used for buttons.
  static let blue = Color(
    red: MessageMark.blue.red, green: MessageMark.blue.green, blue: MessageMark.blue.blue)
  static let selectionInk = adaptive(light: 0x216DE8, dark: 0x70ADFA)
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
  static let roomy: CGFloat = 20
}

enum Radius {
  static let card: CGFloat = 10
  static let control: CGFloat = 7
  static let chip: CGFloat = 5
}

/// Four type roles. Nothing in the panel is smaller than 12 points.
extension Font {
  static let maxTitle = Font.system(size: 15, weight: .semibold)
  static let maxLine = Font.system(size: 13)
  static let maxStrong = Font.system(size: 13, weight: .medium)
  static let maxSmall = Font.system(size: 12)
  static let maxCode = Font.system(size: 12, design: .monospaced)
}

/// Frequency sets speed: presses and hovers are quickest, a page change is
/// the slowest thing the panel does.
enum Move {
  static let hover = Animation.easeOut(duration: 0.10 * Design.motionScale)
  static let press = Animation.snappy(duration: 0.15 * Design.motionScale)
  static let toggle = Animation.snappy(duration: 0.20 * Design.motionScale)
  static let swap = Animation.snappy(duration: 0.25 * Design.motionScale)
  static let step = Animation.snappy(duration: 0.32 * Design.motionScale)
  static let glide = Animation.smooth(duration: 0.25 * Design.motionScale)
}

/// Reduce Motion from the system, or forced by a design-check argument.
@propertyWrapper
struct MotionReduced: DynamicProperty {
  @Environment(\.accessibilityReduceMotion) private var system
  var wrappedValue: Bool { system || Design.reduceMotionOverride }
}

enum CompanionMood: Hashable, CaseIterable {
  case ready, needsYou, working, resting, trouble

  var pose: MaxPose {
    switch self {
    case .ready: .rest
    case .needsYou: .needsYou
    case .working: .working
    case .resting: .asleep
    case .trouble: .trouble
    }
  }
  var idles: Bool { self == .ready || self == .needsYou }
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
  @ObservationIgnored private var blink: DispatchWorkItem?

  private static let sparkTime = 0.6 * Design.motionScale
  private static let sheenTime = 0.9 * Design.motionScale

  func show(_ mood: CompanionMood, animated: Bool) {
    cancel()
    let changed = mood != self.mood
    self.mood = mood
    dots = mood == .working && animated ? .now : nil
    guard animated else {
      place(mood.pose)
      return
    }
    if changed {
      // Every change of face passes through a blink.
      goal[.blink] = 1
      after(0.13) { [weak self] in self?.goal = mood.pose }
    } else {
      goal = mood.pose
    }
    wake()
    scheduleBlink()
  }

  func cheer(animated: Bool) {
    cancel()
    let mood = mood
    guard animated else {
      place(.happy)
      after(1.6) { [weak self] in self?.place(mood.pose) }
      return
    }
    goal = .happy
    kick(1.3)
    sparks = .now
    sheen = .now
    wake()
    after(1.6) { [weak self] in
      self?.goal = mood.pose
      self?.wake()
      self?.scheduleBlink()
    }
  }

  func poke(animated: Bool) {
    guard animated, mood.idles, pending.isEmpty else { return }
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
        let dt = CGFloat(elapsed / 2 / Design.motionScale)
        for part in MaxPose.Part.allCases {
          let (stiffness, damping) = Self.spring(part)
          let index = part.rawValue
          let gap = goal.values[index] - pose.values[index]
          speed[index] += (stiffness * gap - damping * speed[index]) * dt
          pose.values[index] += speed[index] * dt
          if abs(speed[index]) > 0.02 || abs(gap) > 0.005 { moving = true }
        }
      }
      if let start = sparks, date.timeIntervalSince(start) > Self.sparkTime { sparks = nil }
      if let start = sheen, date.timeIntervalSince(start) > Self.sheenTime { sheen = nil }
      settled = !moving && sparks == nil && dots == nil && sheen == nil
      if settled {
        pose = goal
        speed = speed.map { _ in 0 }
      }
    }
    var drawn = pose
    if let dots {
      // The three dots hop in turn, 0.4 s each, like a typing indicator.
      let time = date.timeIntervalSince(dots) / Design.motionScale
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
      drawn, sparks.map { CGFloat(date.timeIntervalSince($0) / Self.sparkTime) },
      sheen.map { CGFloat(date.timeIntervalSince($0) / Self.sheenTime) }
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

  private func scheduleBlink() {
    blink?.cancel()
    guard mood.idles else { return }
    let item = DispatchWorkItem { [weak self] in
      guard let self, pending.isEmpty else { return }
      goal[.blink] = 1
      wake()
      after(0.13) { [weak self] in
        guard let self else { return }
        goal = mood.pose
        wake()
        scheduleBlink()
      }
    }
    blink = item
    DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 2.5...6), execute: item)
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
      deadline: .now() + seconds * Design.motionScale, execute: item!)
  }

  private func cancel() {
    pending.forEach { $0.cancel() }
    pending.removeAll()
    blink?.cancel()
    blink = nil
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
  @MotionReduced private var reduceMotion

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
        context.fill(Path(MaxFace.sparkle(frame.pose, in: rect)), with: .color(.white))
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
    .onTapGesture { engine.poke(animated: awake && !reduceMotion) }
    .onAppear { engine.show(mood, animated: false) }
    .onChange(of: mood) { engine.show(mood, animated: awake && !reduceMotion) }
    .onChange(of: celebration) { if awake { engine.cheer(animated: !reduceMotion) } }
    .onChange(of: awake) {
      if awake { engine.show(mood, animated: !reduceMotion) } else { engine.sleep() }
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Controls

/// A drawn switch: the knob slides, the track changes role colour.
struct MaxSwitchStyle: ToggleStyle {
  @Environment(\.isEnabled) private var enabled
  @MotionReduced private var reduceMotion

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
    .animation(reduceMotion ? nil : Move.toggle, value: configuration.isOn)
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }
    }
  }
}

struct MaxButtonStyle: ButtonStyle {
  var primary = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.colorSchemeContrast) private var contrast
  @MotionReduced private var reduceMotion
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
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .onHover { hovering = $0 }
      .animation(reduceMotion ? nil : Move.hover, value: hovering)
      .animation(reduceMotion ? nil : Move.press, value: configuration.isPressed)
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
  @MotionReduced private var reduceMotion

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
    .animation(reduceMotion ? nil : Move.swap, value: detail)
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
  @MotionReduced private var reduceMotion

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
    .animation(reduceMotion ? nil : Move.hover, value: hovering)
    .accessibilityHint("Show \(title.lowercased())")
  }
}

struct IconButton: View {
  let glyph: Glyph
  let label: String
  let action: () -> Void
  @State private var hovering = false
  @MotionReduced private var reduceMotion

  var body: some View {
    Button(action: action) {
      AppGlyph(glyph: glyph, size: 14).foregroundStyle(Design.muted)
        .frame(width: 24, height: 24)
        .background(hovering ? Design.well : .clear, in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(reduceMotion ? nil : Move.hover, value: hovering)
    .help(label).accessibilityLabel(label)
  }
}

struct CopyButton: View {
  let title: String
  let action: () -> Void
  @State private var copied = false
  @MotionReduced private var reduceMotion

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
    .animation(reduceMotion ? nil : Move.swap, value: copied)
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
