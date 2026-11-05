import AppKit
import MaxBrand
import MaxCore
import SwiftUI

// Design checks (see macos/README.md): command-line flags that show canned
// states, pin appearance and motion for this process, and capture artwork.
// Nothing here changes the Mac's settings, and a fixture never contacts the
// real service.

struct DesignOptions {
  var appearance: NSAppearance.Name?
  /// `--design-artwork <file.png>`: write the menu bar contact sheet and exit.
  var artworkSheet: URL?
  /// `--design-state <name>`: a canned service state from `FixtureService`.
  var fixture: String?
  /// `--design-window`: show the panel in a floating window, not a popover.
  var window = false
  var page: PanelSection?
  var act: String?
  var motion = MotionSettings()

  init(arguments: [String] = CommandLine.arguments) {
    func value(_ flag: String) -> String? {
      guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
      else { return nil }
      return arguments[index + 1]
    }
    if arguments.contains("--design-light") { appearance = .aqua }
    if arguments.contains("--design-dark") { appearance = .darkAqua }
    artworkSheet = value("--design-artwork").map { URL(fileURLWithPath: $0) }
    fixture = value("--design-state")
    window = arguments.contains("--design-window")
    page = value("--design-open").flatMap(PanelSection.init(rawValue:))
    act = value("--design-act")
    motion = MotionSettings(
      scale: arguments.contains("--design-slow-motion") ? 4 : 1,
      reduce: arguments.contains("--design-reduce-motion"))
  }

  /// A fixture or design window replaces the background monitoring.
  var isActive: Bool { fixture != nil || window }

  /// Loads the first state; the "working" fixture then holds a start open.
  @MainActor func prepare(_ model: AppModel) {
    Task {
      await model.refresh()
      if fixture == "working" { model.perform(.start) }
    }
  }

  /// A plain window that stays put, so every state can be captured without
  /// opening the real popover. Prints its window number for screenshots.
  @MainActor func showWindow(_ hosting: NSViewController, model: AppModel) -> NSWindow {
    let window = NSWindow(contentViewController: hosting)
    window.styleMask = [.borderless]
    window.level = .floating
    window.appearance = NSApp.appearance
    window.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 40))
    window.orderFrontRegardless()
    model.panelOpen = true
    if let page { model.section = page }
    if let act {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        switch act {
        case "start": model.perform(.start)
        case "stop": model.perform(.stop)
        case "allow": model.request(.contacts)
        case "copy": model.copy("")
        default: break
        }
      }
    }
    print(window.windowNumber)
    fflush(stdout)
    return window
  }
}

extension AppModel {
  static func designFixture(_ name: String, milestones: Milestones) -> AppModel {
    AppModel(service: FixtureService(name), milestones: milestones, prepareMessages: {})
  }
}

/// Canned service states: `fresh`, `stopped`, `setup-messages`,
/// `setup-contacts`, `setup-sending`, `problem`, `working`, `checking`, and
/// `ready` (also the fallback). A start, stop, or permission request takes a
/// moment and then lands on the state it would reach.
actor FixtureService: ServiceControlling {
  private static let processID: Int32 = 4242
  private var name: String
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(_ name: String) {
    self.name = name
  }

  func inspect() async throws -> ServiceInspection {
    // A first check that never answers.
    while name == "checking" { await withCheckedContinuation { waiting.append($0) } }
    return try Self.inspection(name)
  }

  func perform(_ action: ServiceAction) async throws {
    // An action that stays under way.
    while name == "working" { await withCheckedContinuation { waiting.append($0) } }
    await Self.pause()
    land(on: action == .stop ? "stopped" : "ready")
  }

  func requestPermission(_ permission: PermissionKind) async throws -> SetupPermissionReply {
    await Self.pause()
    land(on: "ready")
    return SetupPermissionReply(
      permission: permission, authorized: true, status: "authorized", processID: Self.processID)
  }

  private func land(on state: String) {
    name = state
    for continuation in waiting { continuation.resume() }
    waiting.removeAll()
  }

  private static func pause() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { continuation.resume() }
    }
  }

  private static func inspection(_ name: String) throws -> ServiceInspection {
    let installed = try PropertyListSerialization.data(
      fromPropertyList: [
        "Label": ServiceConfiguration.label,
        "ProgramArguments": ["/usr/local/bin/imessage-max", "--http"],
      ], format: .xml, options: 0)
    func diagnosis(messages: Bool, contacts: String, sending: String, detail: String? = nil)
      -> Diagnosis?
    {
      typealias Key = Diagnosis.Capability.Key
      let supported = Diagnosis.Capability.supported
      let json: [String: Any] = [
        "version": "1.8.0", "process_id": processID, "status": "ok",
        "database": [
          "accessible": messages, "status": messages ? "accessible" : "permission_denied",
        ],
        "contacts": ["authorized": contacts == "authorized", "status": contacts],
        "capabilities": [
          Key.automation.rawValue: ["state": sending, "detail": detail as Any? ?? NSNull()],
          Key.sendText.rawValue: ["state": supported], Key.liveInbox.rawValue: ["state": supported],
        ],
      ]
      return (try? JSONSerialization.data(withJSONObject: json)).flatMap {
        try? JSONDecoder().decode(Diagnosis.self, from: $0)
      }
    }
    let ready = diagnosis(
      messages: true, contacts: "authorized", sending: Diagnosis.Capability.supported)
    var loaded = true
    var data: Data? = installed
    var result: Diagnosis?
    var trouble: String?
    switch name {
    case "fresh": (loaded, data) = (false, nil)
    case "stopped": loaded = false
    case "setup-messages":
      result = diagnosis(messages: false, contacts: "not_determined", sending: "unknown")
    case "setup-contacts":
      result = diagnosis(messages: true, contacts: "not_determined", sending: "unknown")
    case "setup-sending":
      result = diagnosis(
        messages: true, contacts: "authorized", sending: "unknown", detail: "messages_not_running")
    case "problem": trouble = CoreError.invalidResponse.errorDescription
    default: result = ready
    }
    return ServiceInspection(
      configuration: try ServiceConfiguration(
        data: data, home: FileManager.default.homeDirectoryForCurrentUser),
      loaded: loaded, processID: loaded ? processID : nil,
      diagnosis: result, problem: trouble, conflict: false)
  }
}

/// Every menu bar mood, enlarged on a light and a dark bar.
@MainActor func writeArtworkSheet(to url: URL) {
  let moods = CompanionMood.allCases
  let (cell, zoom) = (CGFloat(36), CGFloat(6))
  let size = NSSize(width: cell * CGFloat(moods.count) * zoom, height: cell * 2 * zoom)
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  for (row, dark) in [false, true].enumerated() {
    (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
    NSRect(x: 0, y: CGFloat(row) * cell * zoom, width: size.width, height: cell * zoom).fill()
    for (column, mood) in moods.enumerated() {
      let image = MenuBarArtwork.image(for: mood).copy() as! NSImage
      image.isTemplate = false
      let side = MenuBarArtwork.points * zoom
      let rect = NSRect(
        x: (CGFloat(column) * cell + (cell - MenuBarArtwork.points) / 2) * zoom,
        y: (CGFloat(row) * cell + (cell - MenuBarArtwork.points) / 2) * zoom, width: side,
        height: side)
      if dark {
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
      }
      image.draw(in: rect)
    }
  }
  try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
}
