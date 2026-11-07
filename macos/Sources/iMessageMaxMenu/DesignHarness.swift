import AppKit
import IMessageMaxContract
import MaxBrand
import MaxCore
import SwiftUI

struct DesignOptions {
  var appearance: NSAppearance.Name?
  var artworkSheet: URL?
  var fixture: String?
  var window = false
  var page: PanelSection?
  var act: String?
  /// `--client-root <folder>`: client configs are read and written there.
  var clientRoot: URL?
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
    clientRoot = value("--client-root").map { URL(fileURLWithPath: $0, isDirectory: true) }
    motion = MotionSettings(
      scale: arguments.contains("--design-slow-motion") ? 4 : 1,
      reduce: arguments.contains("--design-reduce-motion"))
  }

  var isActive: Bool { fixture != nil || window }

  @MainActor func prepare(_ model: AppModel) {
    Task {
      await model.refresh()
      if fixture == "working" { model.perform(.restart) }
    }
  }

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
  /// A fixture drives the real controller through a fake system, so the
  /// design states are the states the controller derives.
  static func designFixture(_ name: String, milestones: Milestones, clientRoot: URL?) -> AppModel {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("imessage-max-design")
    let app = name == "misplaced" ? "/Users/Shared/Downloads" : "/Applications"
    let plist = try? PropertyListSerialization.data(
      fromPropertyList: [
        "Label": ServiceDefaults.launchdLabel,
        "BundleProgram": ServiceDefaults.helperBundlePath,
        "AssociatedBundleIdentifiers": [ServiceDefaults.companionBundleID],
        "ProgramArguments": [ServiceDefaults.executableName, ServerOption.http.flag],
      ], format: .xml, options: 0)
    let configuration = plist.flatMap {
      try? ServiceConfiguration(
        plist: $0, plistName: "\(ServiceDefaults.launchdLabel).plist",
        bundleIdentifier: ServiceDefaults.companionBundleID,
        bundleURL: URL(fileURLWithPath: "\(app)/iMessage Max.app"), home: home)
    }
    return AppModel(
      controller: configuration.map {
        ServiceController(configuration: $0, system: FixtureSystem(name), home: home)
      },
      milestones: milestones, prepareMessages: {},
      clientContext: clientRoot.map(ClientContext.sandbox(root:)))
  }
}

actor FixtureSystem: ServiceSystem {
  private static let processID: Int32 = 4242
  private var name: String
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(_ name: String) {
    self.name = name
  }

  func agentStatus(plistName: String) async -> AgentStatus {
    switch name {
    case "fresh", "legacy": .notRegistered
    case "blocked": .requiresApproval
    default: .enabled
    }
  }

  func job(label: String) async -> Job? {
    if label == LegacyInstall.label { return name == "legacy" ? Job(pid: 77) : nil }
    return switch name {
    case "fresh", "legacy", "blocked", "stopped": nil
    default: Job(pid: Self.processID)
    }
  }

  func diagnose(endpoint: URL) async -> DiagnoseReply {
    while name == "checking" { await withCheckedContinuation { waiting.append($0) } }
    if name == "refused" { return .refused }
    return Self.diagnosis(name).map(DiagnoseReply.answered) ?? .silent
  }

  func listeners(port: Int) async -> Set<Int32> { [] }

  func run(_ command: SystemCommand) async throws {
    while name == "working" { await withCheckedContinuation { waiting.append($0) } }
    await Self.pause(1.2)
    switch command {
    case .unregister: land(on: "fresh")
    case .bootout(let label): land(on: label == LegacyInstall.label ? "fresh" : "stopped")
    case .register, .kickstart: land(on: "ready")
    }
  }

  func isOutdated(pid: Int32, executable: URL) async -> Bool { false }

  func requestContactsAccess() async -> PermissionStatus {
    await Self.pause(1.2)
    return .authorized
  }

  func requestHelperPermission(_ permission: SetupPermission, endpoint: URL, processID: Int32)
    async throws -> SetupPermissionReply
  {
    await Self.pause(1.2)
    land(on: "ready")
    return SetupPermissionReply(
      permission: permission, authorized: true, status: .authorized, processID: processID)
  }

  func pause() async { await Self.pause(0.1) }

  private func land(on state: String) {
    name = state
    for continuation in waiting { continuation.resume() }
    waiting.removeAll()
  }

  private static func pause(_ seconds: Double) async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
  }

  private static func diagnosis(_ name: String) -> DiagnoseResult? {
    func diagnosis(
      messages: Bool, contacts: PermissionStatus, sending: CapabilityState,
      detail: PermissionStatus? = nil
    ) -> DiagnoseResult {
      DiagnoseResult(
        version: "1.8.0", processID: processID,
        status: messages && contacts == .authorized ? .ready : .needsSetup,
        database: .init(
          accessible: messages, status: messages ? .accessible : .permissionDenied,
          path: "~/Library/Messages/chat.db", fix: nil),
        contacts: .init(
          authorized: contacts == .authorized, status: contacts, loaded: nil, fix: nil),
        capabilities: [
          CapabilityKey.permAutomation.rawValue: Capability(state: sending, detail: detail?.rawValue),
          CapabilityKey.sendTextDM.rawValue: Capability(state: .supported),
          CapabilityKey.liveInbox.rawValue: Capability(state: .supported),
        ])
    }
    return switch name {
    case "fresh", "stopped", "legacy", "blocked", "problem": nil
    case "setup-messages":
      diagnosis(messages: false, contacts: .notDetermined, sending: .unverified)
    case "setup-contacts":
      diagnosis(messages: true, contacts: .notDetermined, sending: .unverified)
    case "setup-sending":
      diagnosis(
        messages: true, contacts: .authorized, sending: .unverified, detail: .messagesNotRunning)
    default: diagnosis(messages: true, contacts: .authorized, sending: .supported)
    }
  }
}


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
