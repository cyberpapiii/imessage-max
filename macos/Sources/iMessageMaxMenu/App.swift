import AppKit
import Observation
import SwiftUI

@main
struct iMessageMaxMenuApp {
  @MainActor static func main() {
    let app = NSApplication.shared
    // Process-only design checks never change the Mac's appearance settings.
    if CommandLine.arguments.contains("--design-light") {
      app.appearance = NSAppearance(named: .aqua)
    }
    if CommandLine.arguments.contains("--design-dark") {
      app.appearance = NSAppearance(named: .darkAqua)
    }
    if let path = AppDelegate.argument("--design-artwork") {
      writeArtworkSheet(to: URL(fileURLWithPath: path))
      return
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
      app.run()
    }
  }
}

/// Every menu bar mood, enlarged on a light and a dark bar, for design checks.
@MainActor private func writeArtworkSheet(to url: URL) {
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

/// AppKit owns only the status-item/popover lifecycle. A public MenuBarExtra
/// API cannot present on app launch or reopen; grandma-simple discovery needs
/// both. The entire panel and its state remain SwiftUI/Observation.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
  private let model = AppModel(fixture: AppDelegate.argument("--design-state"))
  private var designWindow: NSWindow?

  /// The value following a design-check flag on the command line.
  static func argument(_ flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
    else { return nil }
    return arguments[index + 1]
  }
  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
  private var keyMonitor: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem = item
    item.button?.target = self
    item.button?.action = #selector(togglePanel)
    popover.behavior = .transient
    popover.delegate = self
    popover.appearance = NSApp.appearance
    popover.animates =
      !(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || Design.reduceMotionOverride)
    let hosting = NSHostingController(
      rootView: PanelView(
        model: model, dismissPanel: { [weak self] in self?.popover.performClose(nil) }
      )
    )

    hosting.sizingOptions = [.preferredContentSize]
    updateStatusItem()
    if CommandLine.arguments.contains("--design-window") {
      showDesignWindow(hosting)
      return
    }
    popover.contentViewController = hosting
    model.startMonitoring()
    // The first launch and reopening the app reveal where it lives. Login
    // launches stay quiet after that first introduction.
    if !UserDefaults.standard.bool(forKey: "hasIntroducedMenuBar") {
      UserDefaults.standard.set(true, forKey: "hasIntroducedMenuBar")
      showPanel()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showPanel()
    return false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard model.busy != nil else { return .terminateNow }
    Task {
      await model.prepareToQuit()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  @objc private func togglePanel() {
    if popover.isShown { popover.performClose(nil) } else { showPanel() }
  }

  private func showPanel() {
    guard let button = statusItem?.button else { return }
    model.maximumPanelHeight = min(720, (button.window?.screen?.visibleFrame.height ?? 732) - 12)
    model.panelOpen = true
    NSApp.activate(ignoringOtherApps: true)
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
    if keyMonitor == nil {
      // Local monitors run on NSApplication's main event-dispatch thread. This
      // is a narrow responder bridge: only Escape in our shown panel is taken.
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let handled = MainActor.assumeIsolated {
          guard let self, self.popover.isShown, event.keyCode == 53,
            event.window === self.popover.contentViewController?.view.window
          else { return false }
          if self.model.section != nil {
            self.model.section = nil
          } else {
            self.popover.performClose(nil)
          }
          return true
        }
        return handled ? nil : event
      }
    }
    Task { await model.refresh() }
  }

  func popoverDidClose(_ notification: Notification) {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    model.section = nil
    model.panelOpen = false
    model.clearNotice()
  }

  /// Design checks show the panel in a plain window that stays put, so every
  /// state can be captured without opening the real popover.
  private func showDesignWindow(_ hosting: NSViewController) {
    let window = NSWindow(contentViewController: hosting)
    window.styleMask = [.borderless]
    window.level = .floating
    window.appearance = NSApp.appearance
    window.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 40))
    window.orderFrontRegardless()
    designWindow = window
    model.panelOpen = true
    if let open = Self.argument("--design-open") { model.section = PanelSection(rawValue: open) }
    if let act = Self.argument("--design-act") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [model] in
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
  }

  private func updateStatusItem() {
    withObservationTracking {
      let mood = model.mood
      let title = "iMessage Max, \(model.title)"
      statusItem?.button?.image = MenuBarArtwork.image(for: mood)
      statusItem?.button?.image?.isTemplate = true
      statusItem?.button?.toolTip = title
      statusItem?.button?.setAccessibilityLabel(title)
    } onChange: { [weak self] in
      Task { @MainActor in self?.updateStatusItem() }
    }
  }
}
